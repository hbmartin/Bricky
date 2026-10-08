import XCTest
import simd
@testable import Bricky

/// The store's one flatten must give every consumer the geometry a per-step
/// snapshot gave it, so recovery scores cannot move (M2.0).
final class PlacementGeometryStoreTests: XCTestCase {
    private var source: URL!
    private var pack: URL!

    override func setUpWithError() throws {
        source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        pack = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        // A 2×4×1 brick-sized box in LDU (40 × 24 × 20), top at y = −24.
        let box = """
        0 BFC CERTIFY CCW
        4 16 -20 -24 -10 20 -24 -10 20 -24 10 -20 -24 10
        4 16 -20 0 -10 -20 0 10 20 0 10 20 0 -10
        4 16 -20 0 10 -20 -24 10 20 -24 10 20 0 10
        4 16 -20 0 -10 20 0 -10 20 -24 -10 -20 -24 -10
        4 16 20 0 -10 20 0 10 20 -24 10 20 -24 -10
        4 16 -20 0 -10 -20 -24 -10 -20 -24 10 -20 0 10
        """
        try Data(box.utf8).write(to: source.appendingPathComponent("box.dat"))
        // Four steps: a base, a brick on it, two more side by side.
        let main = """
        0 Ladder
        1 4 0 0 0 1 0 0 0 1 0 0 0 1 box.dat
        0 STEP
        1 1 0 -24 0 1 0 0 0 1 0 0 0 1 box.dat
        0 STEP
        1 2 40 0 0 1 0 0 0 1 0 0 0 1 box.dat
        1 14 -40 0 0 1 0 0 0 1 0 0 0 1 box.dat
        0 STEP
        1 1 40 -24 0 1 0 0 0 1 0 0 0 1 box.dat
        0 STEP
        """
        try Data(main.utf8).write(to: source.appendingPathComponent("main.ldr"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: source)
        try? FileManager.default.removeItem(at: pack)
    }

    private func makePlan() throws -> InstructionPlan {
        let files = try ["box.dat", "main.ldr"].map {
            InstructionSourceFile(relativePath: $0, data: try Data(contentsOf: source.appendingPathComponent($0)))
        }
        let document = try LDrawInstructionParser().parse(files: files.filter { $0.relativePath.hasSuffix(".ldr") }, rootRelativePath: "main.ldr")
        return try InstructionPlanBuilder().build(
            document: document, title: "Ladder", sourceFilename: "main.ldr",
            sourceSHA256: InstructionSourceIdentity.sha256(of: files)
        )
    }

    private func bits(_ snapshot: InstructionGeometrySnapshot) -> [[UInt32]] {
        snapshot.buffers.map { buffer in
            [UInt32(truncatingIfNeeded: buffer.colorCode)]
                + buffer.positions.flatMap { [$0.x.bitPattern, $0.y.bitPattern, $0.z.bitPattern] }
                + buffer.normals.flatMap { [$0.x.bitPattern, $0.y.bitPattern, $0.z.bitPattern] }
        }
    }

    func testStepGeometryIsIdenticalToPerStepSnapshots() async throws {
        let plan = try makePlan()
        XCTAssertEqual(plan.steps.count, 4)
        let store = PlacementGeometryStore()
        let geometry = try await store.geometry(for: plan, sourceRoot: source, partPackRoot: pack)
        let engine = LDrawGeometryEngine(sourceRoot: source, partPackRoot: pack)
        for step in plan.steps {
            let cumulative = try await engine.snapshot(placements: plan.cumulativePlacements(through: step))
            let completed = try await engine.snapshot(placements: plan.completedPlacements(before: step))
            let delta = try await engine.snapshot(placements: plan.addedPlacements(for: step))
            XCTAssertEqual(bits(geometry.cumulativeSnapshot(through: step)), bits(cumulative), "cumulative \(step.index)")
            XCTAssertEqual(bits(geometry.completedSnapshot(before: step)), bits(completed), "completed \(step.index)")
            XCTAssertEqual(bits(geometry.deltaSnapshot(for: step)), bits(delta), "delta \(step.index)")
            XCTAssertEqual(geometry.cumulativeSnapshot(through: step).bounds, cumulative.bounds)
        }
    }

    /// Recovery scores every candidate on the same snapshot it used to
    /// flatten for itself, so every score field is unchanged.
    func testStoreCandidatesScoreIdenticallyToLegacy() async throws {
        let plan = try makePlan()
        let renderer: ExpectedDepthRenderer
        do { renderer = try ExpectedDepthRenderer() } catch { throw XCTSkip("Metal unavailable in this test environment") }
        let geometry = try await PlacementGeometryStore().geometry(for: plan, sourceRoot: source, partPackRoot: pack)
        let engine = LDrawGeometryEngine(sourceRoot: source, partPackRoot: pack)
        // Observe step 3's build from an oblique camera.
        let observed = geometry.cumulativeSnapshot(through: plan.steps[2])
        var intrinsics = matrix_identity_float3x3
        intrinsics[0][0] = 210; intrinsics[1][1] = 210; intrinsics[2][0] = 128; intrinsics[2][1] = 96
        let eye = SIMD3<Float>(0.15, 0.25, 0.25)
        let forward = simd_normalize(SIMD3<Float>(0, -0.01, 0) - eye)
        let xAxis = simd_normalize(simd_cross(SIMD3(0, 1, 0), -forward))
        var worldFromCamera = matrix_identity_float4x4
        worldFromCamera.columns.0 = SIMD4(xAxis, 0)
        worldFromCamera.columns.1 = SIMD4(simd_cross(-forward, xAxis), 0)
        worldFromCamera.columns.2 = SIMD4(-forward, 0)
        worldFromCamera.columns.3 = SIMD4(eye, 1)
        let map = try renderer.render(
            snapshot: observed, viewFromModel: worldFromCamera.inverse, intrinsics: intrinsics, width: 256, height: 192
        )
        let frame = RegistrationFrameInput(
            depth: map.depth, confidence: .init(repeating: 2, count: map.depth.count), rawDepth: nil, rawConfidence: nil,
            width: 256, height: 192, depthIntrinsics: intrinsics, worldFromCamera: worldFromCamera, timestamp: 0
        )
        var legacy: [(index: Int, snapshot: InstructionGeometrySnapshot)] = []
        var stored: [(index: Int, snapshot: InstructionGeometrySnapshot)] = []
        for (index, step) in plan.steps.enumerated() {
            legacy.append((index, try await engine.snapshot(placements: plan.cumulativePlacements(through: step))))
            stored.append((index, geometry.cumulativeSnapshot(through: step)))
        }
        let a = try await GeometricRecoveryEstimator.scoreCandidates(
            candidates: legacy, frame: frame, coarseWorldFromModel: matrix_identity_float4x4, renderer: renderer
        )
        let b = try await GeometricRecoveryEstimator.scoreCandidates(
            candidates: stored, frame: frame, coarseWorldFromModel: matrix_identity_float4x4, renderer: renderer
        )
        XCTAssertEqual(a.count, b.count)
        for (x, y) in zip(a, b) {
            XCTAssertEqual(x.index, y.index)
            XCTAssertEqual(x.score.bitPattern, y.score.bitPattern, "score \(x.index)")
            XCTAssertEqual(x.unexplainedFraction.bitPattern, y.unexplainedFraction.bitPattern)
            XCTAssertEqual(x.phantomFraction.bitPattern, y.phantomFraction.bitPattern)
            XCTAssertEqual(x.visibleFraction.bitPattern, y.visibleFraction.bitPattern)
            XCTAssertEqual(x.quality, y.quality)
            XCTAssertEqual(x.worldFromModel, y.worldFromModel)
            XCTAssertEqual(x.disqualification, y.disqualification)
        }
    }

    func testStoreFlattensOnceAndDedupesConcurrentRequests() async throws {
        let plan = try makePlan()
        let store = PlacementGeometryStore()
        async let first = store.geometry(for: plan, sourceRoot: source, partPackRoot: pack)
        async let second = store.geometry(for: plan, sourceRoot: source, partPackRoot: pack)
        _ = try await (first, second)
        _ = try await store.geometry(for: plan, sourceRoot: source, partPackRoot: pack)
        let builds = await store.buildCount
        XCTAssertEqual(builds, 1)
    }

    /// Holds the first build until released.
    private actor BuildGate {
        private(set) var isHolding = false
        private var hasHeld = false
        private var held: CheckedContinuation<Void, Never>?

        func holdOnce() async {
            guard !hasHeld else { return }
            hasHeld = true
            isHolding = true
            await withCheckedContinuation { held = $0 }
        }

        func release() {
            held?.resume()
            held = nil
        }
    }

    /// The AR guide closing during a build must not leave that build's
    /// geometry in memory.
    func testAPurgeDuringABuildLeavesNothingCached() async throws {
        let plan = try makePlan()
        let gate = BuildGate()
        let store = PlacementGeometryStore(build: { plan, sourceRoot, partPackRoot in
            await gate.holdOnce()
            return try await PlacementGeometryStore.flatten(plan, sourceRoot: sourceRoot, partPackRoot: partPackRoot)
        })
        let (source, pack) = (source!, pack!)
        let first = Task { try await store.geometry(for: plan, sourceRoot: source, partPackRoot: pack) }
        let deadline = ContinuousClock.now + .seconds(10)
        while await !gate.isHolding, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        await store.purge()
        await gate.release()
        _ = try await first.value
        _ = try await store.geometry(for: plan, sourceRoot: source, partPackRoot: pack)
        let builds = await store.buildCount
        XCTAssertEqual(builds, 2, "the purged build's geometry was cached anyway")
    }

    func testKeyIncludesPartPackRoot() async throws {
        let plan = try makePlan()
        let store = PlacementGeometryStore()
        _ = try await store.geometry(for: plan, sourceRoot: source, partPackRoot: pack)
        let otherPack = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: otherPack, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: otherPack) }
        _ = try await store.geometry(for: plan, sourceRoot: source, partPackRoot: otherPack)
        await store.purge()
        _ = try await store.geometry(for: plan, sourceRoot: source, partPackRoot: otherPack)
        let builds = await store.buildCount
        XCTAssertEqual(builds, 3, "a different pack and a purge each rebuild")
    }
}
