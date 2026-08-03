import Foundation
import SwiftData

@Model
final class StoredInstructionModel {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var sourceSHA256: String
    var title: String
    var sourceFilename: String
    var planRelativePath: String
    var importedAt: Date
    var totalSteps: Int
    var currentStepIndex: Int
    var confirmedLastCompletedStepID: String?
    var lastOpenedAt: Date
    var validationWarningCount: Int

    init(plan: InstructionPlan) {
        id = plan.id
        sourceSHA256 = plan.sourceSHA256
        title = plan.title
        sourceFilename = plan.sourceFilename
        planRelativePath = "Models/\(plan.sourceSHA256)/plan.json"
        importedAt = plan.importedAt
        totalSteps = plan.steps.count
        currentStepIndex = 0
        confirmedLastCompletedStepID = nil
        lastOpenedAt = plan.importedAt
        validationWarningCount = plan.document.diagnostics.filter { $0.severity == .warning }.count
    }
}

@Model
final class RecoverySessionRecord {
    @Attribute(.unique) var id: UUID
    var modelID: UUID
    var confirmedLastCompletedStepID: String?
    var nextTargetStepID: String?
    var createdAt: Date
    var updatedAt: Date
    var modelRevision: String?
    var certaintyRawValue: String?

    init(modelID: UUID) {
        id = UUID()
        self.modelID = modelID
        createdAt = .now
        updatedAt = .now
    }
}

@Model
final class StepMilestoneRecord {
    @Attribute(.unique) var id: UUID
    var modelID: UUID
    var stepID: String
    var imageRelativePath: String
    var byteCount: Int64
    var createdAt: Date
    var isInitialRecoveryView: Bool

    init(
        modelID: UUID,
        stepID: String,
        imageRelativePath: String,
        byteCount: Int64,
        isInitialRecoveryView: Bool
    ) {
        id = UUID()
        self.modelID = modelID
        self.stepID = stepID
        self.imageRelativePath = imageRelativePath
        self.byteCount = byteCount
        createdAt = .now
        self.isInitialRecoveryView = isInitialRecoveryView
    }
}

enum InstructionPersistence {
    static let schema = Schema([
        StoredInstructionModel.self,
        RecoverySessionRecord.self,
        StepMilestoneRecord.self
    ])

    static func container() throws -> ModelContainer {
        let root = try InstructionModelImporter.applicationSupportRoot()
        let storeURL = root.appendingPathComponent("Library.sqlite")
        let configuration = ModelConfiguration("InstructionLibraryV1", schema: schema, url: storeURL, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
