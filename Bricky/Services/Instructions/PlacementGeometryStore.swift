import Foundation

/// One plan's placement timeline, flattened once (M2.0). Every step's
/// completed, delta, and cumulative geometry is a range of it, merged by
/// colour exactly as `LDrawGeometryEngine.snapshot` would merge the same
/// placements.
struct PlacementGeometry: Sendable {
    let segments: SegmentedGeometry

    /// Everything built through `step`.
    func cumulativeSnapshot(through step: AuthoredStep) -> InstructionGeometrySnapshot {
        segments.mergedByColour(prefix: step.cumulativePlacementCount)
    }

    /// Everything built before `step`.
    func completedSnapshot(before step: AuthoredStep) -> InstructionGeometrySnapshot {
        segments.mergedByColour(prefix: step.addedPlacementRange.lowerBound)
    }

    /// What `step` adds.
    func deltaSnapshot(for step: AuthoredStep) -> InstructionGeometrySnapshot {
        segments.mergedByColour(step.addedPlacementRange.lowerBound..<step.addedPlacementRange.upperBound)
    }
}

/// Caches the most recent plan's `PlacementGeometry`, so the AR guide, the
/// verifier and recovery stop re-flattening the same timeline per step and
/// per candidate. One entry: the app works on one model at a time, and the
/// geometry costs about what one full-model snapshot did.
actor PlacementGeometryStore {
    static let shared = PlacementGeometryStore()

    struct Key: Hashable, Sendable {
        let sourceSHA256: String
        let sourceRoot: String
        let partPackRoot: String
        let placementCount: Int
    }

    private var cached: (key: Key, geometry: PlacementGeometry)?
    private var inFlight: (key: Key, task: Task<PlacementGeometry, Error>)?
    /// Flattens performed, for tests.
    private(set) var buildCount = 0

    static func key(for plan: InstructionPlan, sourceRoot: URL, partPackRoot: URL) -> Key {
        Key(
            sourceSHA256: plan.sourceSHA256,
            sourceRoot: sourceRoot.standardizedFileURL.path,
            partPackRoot: partPackRoot.standardizedFileURL.path,
            placementCount: plan.placementTimeline.count
        )
    }

    func geometry(for plan: InstructionPlan, sourceRoot: URL, partPackRoot: URL) async throws -> PlacementGeometry {
        let key = Self.key(for: plan, sourceRoot: sourceRoot, partPackRoot: partPackRoot)
        if let cached, cached.key == key { return cached.geometry }
        if let inFlight, inFlight.key == key { return try await inFlight.task.value }
        buildCount += 1
        let timeline = plan.placementTimeline
        let task = Task {
            let engine = LDrawGeometryEngine(sourceRoot: sourceRoot, partPackRoot: partPackRoot)
            return PlacementGeometry(segments: try await engine.segmented(placements: timeline))
        }
        inFlight = (key, task)
        defer { if inFlight?.key == key { inFlight = nil } }
        let geometry = try await task.value
        cached = (key, geometry)
        return geometry
    }

    /// Drops the cached geometry, e.g. when the AR guide closes.
    func purge() {
        cached = nil
    }
}
