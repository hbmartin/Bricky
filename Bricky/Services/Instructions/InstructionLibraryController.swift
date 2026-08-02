import Foundation
import SwiftData
import UIKit

@MainActor
final class InstructionLibraryController: ObservableObject {
    @Published private(set) var isImporting = false
    @Published var importError: String?
    @Published var rootCandidates: [String] = []
    @Published var pendingFolderURL: URL?

    private let importer: InstructionModelImporter

    init(importer: InstructionModelImporter = .init()) {
        self.importer = importer
    }

    func importSource(_ source: InstructionImportSource, into context: ModelContext) async -> StoredInstructionModel? {
        isImporting = true
        importError = nil
        defer { isImporting = false }
        do {
            let plan = try await importer.import(source: source)
            let hash = plan.sourceSHA256
            let descriptor = FetchDescriptor<StoredInstructionModel>(predicate: #Predicate { $0.sourceSHA256 == hash })
            if let existing = try context.fetch(descriptor).first {
                existing.lastOpenedAt = .now
                try context.save()
                return existing
            }
            let stored = StoredInstructionModel(plan: plan)
            context.insert(stored)
            try context.save()
            return stored
        } catch let InstructionImportError.rootSelectionRequired(candidates) {
            rootCandidates = candidates
            if case let .folder(url, _) = source { pendingFolderURL = url }
            return nil
        } catch {
            importError = error.localizedDescription
            return nil
        }
    }

    func importSelectedRoot(_ root: String, into context: ModelContext) async -> StoredInstructionModel? {
        guard let pendingFolderURL else { return nil }
        rootCandidates = []
        self.pendingFolderURL = nil
        return await importSource(.folder(pendingFolderURL, rootRelativePath: root), into: context)
    }

    func loadPlan(for model: StoredInstructionModel) throws -> InstructionPlan {
        let root = try InstructionModelImporter.applicationSupportRoot()
        let data = try Data(contentsOf: root.appendingPathComponent(model.planRelativePath))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(InstructionPlan.self, from: data)
    }
}

@MainActor
final class RecoveryImageStore {
    private let fileManager = FileManager.default
    private let perModelLimit = 250
    private let globalByteLimit: Int64 = 500 * 1024 * 1024

    func save(
        image: UIImage,
        modelID: UUID,
        stepID: String,
        isInitialRecoveryView: Bool,
        context: ModelContext
    ) throws -> StepMilestoneRecord {
        guard let data = image.normalizedForInference().jpegData(compressionQuality: 0.86) else {
            throw InstructionImportError.invalidDocument("The recovery image could not be encoded.")
        }
        let root = try InstructionModelImporter.applicationSupportRoot(fileManager: fileManager)
        let history = root.appendingPathComponent("History/\(modelID.uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: history, withIntermediateDirectories: true)
        let filename = "\(UUID().uuidString).jpg"
        let relative = "History/\(modelID.uuidString)/\(filename)"
        try data.write(to: history.appendingPathComponent(filename), options: .atomic)
        if !isInitialRecoveryView {
            try removePriorRepresentative(modelID: modelID, stepID: stepID, context: context, root: root)
        }
        let record = StepMilestoneRecord(
            modelID: modelID,
            stepID: stepID,
            imageRelativePath: relative,
            byteCount: Int64(data.count),
            isInitialRecoveryView: isInitialRecoveryView
        )
        context.insert(record)
        try context.save()
        try evictIfNeeded(context: context, root: root)
        return record
    }

    func registerExistingCapture(
        relativePath: String,
        modelID: UUID,
        stepID: String,
        isInitialRecoveryView: Bool,
        context: ModelContext
    ) throws -> StepMilestoneRecord {
        let root = try InstructionModelImporter.applicationSupportRoot(fileManager: fileManager)
        let source = root.appendingPathComponent(relativePath)
        guard fileManager.fileExists(atPath: source.path) else {
            throw InstructionImportError.invalidDocument("A recovery milestone image is missing.")
        }
        if !isInitialRecoveryView {
            try removePriorRepresentative(modelID: modelID, stepID: stepID, context: context, root: root)
        }
        let bytes = Int64((try source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let record = StepMilestoneRecord(
            modelID: modelID,
            stepID: stepID,
            imageRelativePath: relativePath,
            byteCount: bytes,
            isInitialRecoveryView: isInitialRecoveryView
        )
        context.insert(record)
        try context.save()
        try evictIfNeeded(context: context, root: root)
        return record
    }

    func enforceLimits(context: ModelContext) throws {
        try evictIfNeeded(context: context, root: InstructionModelImporter.applicationSupportRoot(fileManager: fileManager))
    }

    private func evictIfNeeded(context: ModelContext, root: URL) throws {
        let descriptor = FetchDescriptor<StepMilestoneRecord>(sortBy: [SortDescriptor(\.createdAt)])
        let all = try context.fetch(descriptor)
        var counts = Dictionary(grouping: all, by: \.modelID).mapValues(\.count)
        var total = all.reduce(Int64(0)) { $0 + $1.byteCount }

        // Initial guided recovery views are retained; confirmed-step milestones
        // are the first eviction class, oldest first.
        var removed = Set<UUID>()
        for record in all where !record.isInitialRecoveryView {
            let exceedsModel = counts[record.modelID, default: 0] > perModelLimit
            let exceedsGlobal = total > globalByteLimit
            guard exceedsModel || exceedsGlobal else { continue }
            try? fileManager.removeItem(at: root.appendingPathComponent(record.imageRelativePath))
            total -= record.byteCount
            counts[record.modelID, default: 1] -= 1
            context.delete(record)
            removed.insert(record.id)
        }

        // The global and per-model caps are hard limits. Initial recovery views
        // are retained preferentially, then evicted oldest-first only when step
        // milestones were insufficient to restore the cap.
        for record in all where !removed.contains(record.id) {
            let exceedsModel = counts[record.modelID, default: 0] > perModelLimit
            let exceedsGlobal = total > globalByteLimit
            guard exceedsModel || exceedsGlobal else { continue }
            try? fileManager.removeItem(at: root.appendingPathComponent(record.imageRelativePath))
            total -= record.byteCount
            counts[record.modelID, default: 1] -= 1
            context.delete(record)
        }
        try context.save()
    }

    private func removePriorRepresentative(
        modelID: UUID,
        stepID: String,
        context: ModelContext,
        root: URL
    ) throws {
        let descriptor = FetchDescriptor<StepMilestoneRecord>(predicate: #Predicate {
            $0.modelID == modelID && $0.stepID == stepID && !$0.isInitialRecoveryView
        })
        for record in try context.fetch(descriptor) {
            try? fileManager.removeItem(at: root.appendingPathComponent(record.imageRelativePath))
            context.delete(record)
        }
    }
}
