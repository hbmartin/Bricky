import XCTest
import simd
@testable import Bricky

/// A suggested ghost is a proposal from geometry, offered only when one
/// pose clearly fits, and never registered until the user accepts it.
@MainActor
final class SuggestedPlacementTests: XCTestCase {
    private let width = 256
    private let height = 192

    private var intrinsics: simd_float3x3 {
        var matrix = matrix_identity_float3x3
        matrix[0][0] = 210; matrix[1][1] = 210; matrix[2][0] = 128; matrix[2][1] = 96
        return matrix
    }

    /// A closed box with true face normals: the sampler and the
    /// point-to-plane solve both read them.
    private func box(_ lo: SIMD3<Float>, _ hi: SIMD3<Float>, colour: Int = 4) -> LDrawGeometryBuffer {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        func face(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>, _ n: SIMD3<Float>) {
            positions.append(contentsOf: [a, b, c, a, c, d])
            normals.append(contentsOf: Array(repeating: n, count: 6))
        }
        face(SIMD3(lo.x, hi.y, lo.z), SIMD3(hi.x, hi.y, lo.z), SIMD3(hi.x, hi.y, hi.z), SIMD3(lo.x, hi.y, hi.z), SIMD3(0, 1, 0))
        face(SIMD3(lo.x, lo.y, lo.z), SIMD3(lo.x, lo.y, hi.z), SIMD3(hi.x, lo.y, hi.z), SIMD3(hi.x, lo.y, lo.z), SIMD3(0, -1, 0))
        face(SIMD3(lo.x, lo.y, hi.z), SIMD3(lo.x, hi.y, hi.z), SIMD3(hi.x, hi.y, hi.z), SIMD3(hi.x, lo.y, hi.z), SIMD3(0, 0, 1))
        face(SIMD3(lo.x, lo.y, lo.z), SIMD3(hi.x, lo.y, lo.z), SIMD3(hi.x, hi.y, lo.z), SIMD3(lo.x, hi.y, lo.z), SIMD3(0, 0, -1))
        face(SIMD3(hi.x, lo.y, lo.z), SIMD3(hi.x, lo.y, hi.z), SIMD3(hi.x, hi.y, hi.z), SIMD3(hi.x, hi.y, lo.z), SIMD3(1, 0, 0))
        face(SIMD3(lo.x, lo.y, lo.z), SIMD3(lo.x, hi.y, lo.z), SIMD3(lo.x, hi.y, hi.z), SIMD3(lo.x, lo.y, hi.z), SIMD3(-1, 0, 0))
        return LDrawGeometryBuffer(colorCode: colour, positions: positions, normals: normals,
                                   indices: positions.indices.map(UInt32.init))
    }

    /// A stepped L, the tracker tests' locking fixture: a 128 × 64 mm base
    /// with a block on one half. Nothing like itself after any turn.
    private var lBuild: InstructionGeometrySnapshot {
        InstructionGeometrySnapshot(buffers: [
            box(SIMD3(-0.064, 0, -0.032), SIMD3(0.064, 0.0384, 0.032)),
            box(SIMD3(-0.064, 0.0384, -0.032), SIMD3(0, 0.0768, 0.032), colour: 1)
        ], bounds: nil)
    }

    private var squareBuild: InstructionGeometrySnapshot {
        InstructionGeometrySnapshot(buffers: [box(SIMD3(-0.032, 0, -0.032), SIMD3(0.032, 0.0384, 0.032))], bounds: nil)
    }

    private var table: LDrawGeometryBuffer {
        box(SIMD3(-0.4, -0.01, -0.4), SIMD3(0.4, 0, 0.4), colour: 0)
    }

    private var camera: simd_float4x4 {
        let eye = SIMD3<Float>(0.30, 0.35, 0.40)
        let zAxis = simd_normalize(eye - SIMD3(0.02, 0.03, 0))
        let xAxis = simd_normalize(simd_cross(SIMD3(0, 1, 0), zAxis))
        return simd_float4x4(SIMD4(xAxis, 0), SIMD4(simd_cross(zAxis, xAxis), 0), SIMD4(zAxis, 0), SIMD4(eye, 1))
    }

    private func renderer() throws -> ExpectedDepthRenderer {
        do { return try ExpectedDepthRenderer() } catch { throw XCTSkip("Metal unavailable in this test environment") }
    }

    private func frame(of buffers: [LDrawGeometryBuffer], renderer: ExpectedDepthRenderer) throws -> RegistrationFrameInput {
        let map = try renderer.render(
            snapshot: InstructionGeometrySnapshot(buffers: buffers + [table], bounds: nil),
            viewFromModel: camera.inverse, intrinsics: intrinsics, width: width, height: height
        )
        return RegistrationFrameInput(
            depth: map.depth, confidence: .init(repeating: 2, count: map.depth.count), rawDepth: nil, rawConfidence: nil,
            width: width, height: height, depthIntrinsics: intrinsics, worldFromCamera: camera, timestamp: 0
        )
    }

    private func reticle(_ world: SIMD3<Float>) -> SIMD2<Int> {
        let point = camera.inverse * SIMD4(world, 1)
        let depth = -point.z
        return SIMD2(Int(210 * point.x / depth + 128), Int(-210 * point.y / depth + 96))
    }

    /// The L built a quarter turn round and 2 cm along x from where the
    /// model frame would put it.
    private var physicalPose: simd_float4x4 {
        var pose = simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3(0, 1, 0)))
        pose.columns.3 = SIMD4(0.02, 0, 0, 1)
        return pose
    }

    private func placed(_ snapshot: InstructionGeometrySnapshot, _ pose: simd_float4x4) -> [LDrawGeometryBuffer] {
        snapshot.buffers.map { buffer in
            LDrawGeometryBuffer(
                colorCode: buffer.colorCode,
                positions: buffer.positions.map { let p = pose * SIMD4($0, 1); return SIMD3(p.x, p.y, p.z) },
                normals: buffer.normals.map { let n = pose * SIMD4($0, 0); return SIMD3(n.x, n.y, n.z) },
                indices: buffer.indices
            )
        }
    }

    func testOnBuildProposesTheTruth() async throws {
        let renderer = try renderer()
        let observed = try frame(of: placed(lBuild, physicalPose), renderer: renderer)
        let outcome = try await SuggestedPlacementEstimator.suggest(
            frame: observed, reticle: reticle(SIMD3(0.02, 0.0384, 0)), planeHeight: 0, build: lBuild, renderer: renderer
        )
        guard case .proposal(let placement) = outcome else { return XCTFail("expected a proposal, got \(outcome)") }
        let translation = simd_distance(
            SIMD3(placement.worldFromModel.columns.3.x, placement.worldFromModel.columns.3.y, placement.worldFromModel.columns.3.z),
            SIMD3(physicalPose.columns.3.x, physicalPose.columns.3.y, physicalPose.columns.3.z)
        )
        XCTAssertLessThanOrEqual(translation, 0.008)
        XCTAssertLessThanOrEqual(abs(SuggestedPlacementEstimator.yawDifferenceDegrees(placement.worldFromModel, physicalPose)), 20)
    }

    func testAmbiguousSquareRefuses() async throws {
        let renderer = try renderer()
        let observed = try frame(of: squareBuild.buffers, renderer: renderer)
        let outcome = try await SuggestedPlacementEstimator.suggest(
            frame: observed, reticle: reticle(SIMD3(0, 0.0384, 0)), planeHeight: 0, build: squareBuild, renderer: renderer
        )
        guard case .noProposal(let reason) = outcome else { return XCTFail("a square fits four ways; got \(outcome)") }
        if case .ambiguous = reason {} else if reason != .poorFit { XCTFail("unexpected \(reason)") }
    }

    func testADistractorGetsNoProposal() async throws {
        let renderer = try renderer()
        let distractor = box(SIMD3(0.14, 0, -0.01), SIMD3(0.18, 0.03, 0.01), colour: 7)
        let observed = try frame(of: lBuild.buffers + [distractor], renderer: renderer)
        let outcome = try await SuggestedPlacementEstimator.suggest(
            frame: observed, reticle: reticle(SIMD3(0.16, 0.03, 0)), planeHeight: 0, build: lBuild, renderer: renderer
        )
        if case .proposal(let placement) = outcome {
            // Only acceptable if it found the real build, not the box.
            XCTAssertLessThan(simd_length(SIMD2(placement.worldFromModel.columns.3.x, placement.worldFromModel.columns.3.z)), 0.03)
        }
    }

    func testBareTableGetsNoProposal() async throws {
        let renderer = try renderer()
        let observed = try frame(of: lBuild.buffers, renderer: renderer)
        let outcome = try await SuggestedPlacementEstimator.suggest(
            frame: observed, reticle: reticle(SIMD3(-0.15, 0, 0.15)), planeHeight: 0, build: lBuild, renderer: renderer
        )
        XCTAssertEqual(outcome, .noProposal(.noBlob))
    }

    func testNoRegistrationBeforeAccept() {
        let controller = ARAlignmentController()
        let placement = SuggestedPlacement(worldFromModel: physicalPose, score: 0.8, runnerUpScore: 0.2, quality: .none)
        controller.offer(.proposal(placement))
        XCTAssertNil(controller.alignment, "a suggestion is drawn, never registered")
        XCTAssertNotNil(controller.suggestion)
        controller.acceptSuggestion()
        XCTAssertEqual(controller.alignment?.transform, physicalPose)
        XCTAssertNil(controller.suggestion)
    }

    func testDecliningLeavesNothingPlaced() {
        let controller = ARAlignmentController()
        controller.offer(.proposal(SuggestedPlacement(worldFromModel: physicalPose, score: 0.8, runnerUpScore: nil, quality: .none)))
        controller.declineSuggestion()
        XCTAssertNil(controller.alignment)
        XCTAssertNil(controller.suggestion)
    }

    func testFitScoringMatchesTheRecoveryFormula() {
        let expected = ExpectedDepthMap(depth: [0.5, 0.5, 0.5, 0, 0.5], width: 5, height: 1)
        let observed: [Float32] = [0.5, 0.47, 0.53, 0.4, 0.5]
        let solve = DepthICPTracker.SolveResult(
            worldFromModel: matrix_identity_float4x4,
            quality: RegistrationQuality(rmsResidual: 0.002, inlierFraction: 0.8, latticeMargin: 2),
            visibleFraction: 0.3
        )
        let fit = FitScoring.score(
            solve: solve, expected: expected, observed: observed, confidence: [2, 2, 2, 2, 2],
            minimumConfidence: 1, unexplainedGap: 0.012, unexplainedWeight: 1.5
        )
        // 4 covered: one in front (unexplained), one behind (phantom).
        XCTAssertEqual(fit.unexplainedFraction, 0.25)
        XCTAssertEqual(fit.phantomFraction, 0.25)
        XCTAssertEqual(fit.score.bitPattern, (Float(0.8) * min(1, Float(0.3) * 2) - 1.5 * (0.25 + 0.25)).bitPattern)
    }
}
