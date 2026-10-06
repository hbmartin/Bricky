import AppIntents
import CoreSpotlight
import Foundation
import SwiftData

/// An imported instruction model, as Siri, Shortcuts and (only when the user
/// turns it on) Spotlight see it (M2.8b, ADR 0016). Title and step count
/// only: never progress, photos or evidence.
struct InstructionModelEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Instruction Model")
    static let defaultQuery = InstructionModelQuery()

    let id: UUID
    let title: String
    let stepCount: Int

    init(id: UUID, title: String, stepCount: Int) {
        self.id = id
        self.title = title
        self.stepCount = stepCount
    }

    init(_ model: StoredInstructionModel) {
        self.init(id: model.id, title: model.title, stepCount: model.totalSteps)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(stepCount) steps")
    }
}

struct InstructionModelQuery: EntityQuery {
    @AppDependency private var container: ModelContainer

    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [InstructionModelEntity] {
        let wanted = Set(identifiers)
        return try InstructionModelSpotlight.entities(in: container.mainContext).filter { wanted.contains($0.id) }
    }

    @MainActor
    func suggestedEntities() async throws -> [InstructionModelEntity] {
        try InstructionModelSpotlight.entities(in: container.mainContext)
    }
}

/// Where model entities are written: Core Spotlight in the app, a
/// recording fake in tests.
protocol InstructionModelIndexing: Sendable {
    func index(_ entities: [InstructionModelEntity]) async throws
    func removeAll() async throws
}

struct SpotlightInstructionModelIndex: InstructionModelIndexing {
    /// One named index, so turning Spotlight off can empty exactly it.
    static let indexName = "com.bricky.instruction-models"

    func index(_ entities: [InstructionModelEntity]) async throws {
        try await CSSearchableIndex(name: Self.indexName).indexAppEntities(entities)
    }

    func removeAll() async throws {
        try await CSSearchableIndex(name: Self.indexName).deleteAppEntities(ofType: InstructionModelEntity.self)
    }
}

/// Keeps Spotlight in step with the library and the user's choice (ADR 0016).
/// Off by default. Off removes every entry; on rewrites the whole set, so a
/// replaced or removed model never lingers.
@MainActor
enum InstructionModelSpotlight {
    nonisolated static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: AppConfig.Defaults.spotlightModelsEnabled)
    }

    static func sync(
        enabled: Bool = isEnabled,
        context: ModelContext,
        index: some InstructionModelIndexing = SpotlightInstructionModelIndex()
    ) async throws {
        try await index.removeAll()
        guard enabled else { return }
        let entities = try entities(in: context)
        guard !entities.isEmpty else { return }
        try await index.index(entities)
    }

    static func entities(in context: ModelContext) throws -> [InstructionModelEntity] {
        let descriptor = FetchDescriptor<StoredInstructionModel>(sortBy: [SortDescriptor(\.lastOpenedAt, order: .reverse)])
        return try context.fetch(descriptor).map(InstructionModelEntity.init)
    }
}
