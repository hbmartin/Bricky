import Foundation

/// One plan's placement timeline, flattened once (M2.0). Every step's
/// completed, delta, and cumulative geometry is a range of it, merged by
/// colour exactly as `LDrawGeometryEngine.snapshot` would merge the same
/// placements.
struct PlacementGeometry: Sendable {
    let segments: SegmentedGeometry
    /// Lattice status, occupancy and support graph, from the same flatten.
    let index: PlacementGeometryIndex

    init(segments: SegmentedGeometry, index: PlacementGeometryIndex) {
        self.segments = segments
        self.index = index
    }

    init(plan: InstructionPlan, segments: SegmentedGeometry) {
        self.init(segments: segments, index: PlacementGeometryIndex.build(plan: plan, segments: segments))
    }

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

    /// Flattens a plan's whole timeline. Injectable for tests.
    typealias Build = @Sendable (InstructionPlan, URL, URL) async throws -> PlacementGeometry
    private let build: Build

    init(build: @escaping Build = PlacementGeometryStore.flatten) {
        self.build = build
    }

    /// The app's flatten: every placement through the LDraw engine.
    static func flatten(_ plan: InstructionPlan, sourceRoot: URL, partPackRoot: URL) async throws -> PlacementGeometry {
        let engine = LDrawGeometryEngine(sourceRoot: sourceRoot, partPackRoot: partPackRoot)
        return PlacementGeometry(plan: plan, segments: try await engine.segmented(placements: plan.placementTimeline))
    }

    struct Key: Hashable, Sendable {
        let sourceSHA256: String
        let sourceRoot: String
        let partPackRoot: String
        let placementCount: Int
    }

    private var cached: (key: Key, geometry: PlacementGeometry)?
    /// Per part reference, for the cached plan's source and pack: a model's
    /// own file can shadow a pack part of the same name.
    private var symmetries: (key: Key, byReference: [String: RotationalSymmetry])?
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
        let build = self.build
        let task = Task { try await build(plan, sourceRoot, partPackRoot) }
        inFlight = (key, task)
        defer { if inFlight?.task == task { inFlight = nil } }
        let geometry = try await task.value
        // A purge, or a request for another model, replaced this build
        // while it ran: its caller gets the geometry, but it is not kept.
        if inFlight?.task == task { cached = (key, geometry) }
        return geometry
    }

    /// How `reference` survives quarter turns, measured once per part.
    func symmetry(
        of reference: String, in plan: InstructionPlan, sourceRoot: URL, partPackRoot: URL
    ) async throws -> RotationalSymmetry {
        let key = Self.key(for: plan, sourceRoot: sourceRoot, partPackRoot: partPackRoot)
        if symmetries?.key != key { symmetries = (key, [:]) }
        if let known = symmetries?.byReference[reference] { return known }
        let engine = LDrawGeometryEngine(sourceRoot: sourceRoot, partPackRoot: partPackRoot)
        // The part alone, in its own frame: identity transform, origin at
        // the footprint centre for LDraw bricks.
        let part = PartPlacement(
            id: "symmetry:\(reference)", partReference: reference, colorCode: 16, transform: LDrawTransform(),
            sourceSection: "", sourceLine: 0, isSubmodelReference: false
        )
        let measured = RotationalSymmetry.measure(positions: try await engine.segmented(placements: [part]).positions)
        if symmetries?.key == key { symmetries?.byReference[reference] = measured }
        return measured
    }

    /// Drops the cached geometry, e.g. when the AR guide closes. A build
    /// still running finishes for whoever awaits it but is not cached.
    func purge() {
        cached = nil
        symmetries = nil
        inFlight = nil
    }
}
