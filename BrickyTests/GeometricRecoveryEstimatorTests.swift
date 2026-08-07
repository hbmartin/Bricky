import XCTest
import simd
@testable import Bricky

final class GeometricRecoveryEstimatorTests: XCTestCase {
    private let width = 256
    private let height = 192

    private var intrinsics: simd_float3x3 {
        var matrix = matrix_identity_float3x3
        matrix[0][0] = 210
        matrix[1][1] = 210
        matrix[2][0] = 128
        matrix[2][1] = 96
        return matrix
    }

    private func boxBuffer(
        min minimum: SIMD3<Float>,
        max maximum: SIMD3<Float>,
        colorCode: Int = 4
    ) -> LDrawGeometryBuffer {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        func face(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>, _ n: SIMD3<Float>) {
            positions.append(contentsOf: [a, b, c, a, c, d])
            normals.append(contentsOf: Array(repeating: n, count: 6))
        }
        let (x0, y0, z0) = (minimum.x, minimum.y, minimum.z)
        let (x1, y1, z1) = (maximum.x, maximum.y, maximum.z)
        face(SIMD3(x0, y1, z0), SIMD3(x1, y1, z0), SIMD3(x1, y1, z1), SIMD3(x0, y1, z1), SIMD3(0, 1, 0))
        face(SIMD3(x0, y0, z0), SIMD3(x0, y0, z1), SIMD3(x1, y0, z1), SIMD3(x1, y0, z0), SIMD3(0, -1, 0))
        face(SIMD3(x0, y0, z1), SIMD3(x0, y1, z1), SIMD3(x1, y1, z1), SIMD3(x1, y0, z1), SIMD3(0, 0, 1))
        face(SIMD3(x0, y0, z0), SIMD3(x1, y0, z0), SIMD3(x1, y1, z0), SIMD3(x0, y1, z0), SIMD3(0, 0, -1))
        face(SIMD3(x1, y0, z0), SIMD3(x1, y0, z1), SIMD3(x1, y1, z1), SIMD3(x1, y1, z0), SIMD3(1, 0, 0))
        face(SIMD3(x0, y0, z0), SIMD3(x0, y1, z0), SIMD3(x0, y1, z1), SIMD3(x0, y0, z1), SIMD3(-1, 0, 0))
        return LDrawGeometryBuffer(
            colorCode: colorCode,
            positions: positions,
            normals: normals,
            indices: Array(0..<UInt32(positions.count))
        )
    }

    /// A three-step build ladder: base plate, plus one brick, plus a second
    /// stacked brick.
    private var base: LDrawGeometryBuffer {
        boxBuffer(min: SIMD3(0, 0, 0), max: SIMD3(0.128, 0.0192, 0.064))
    }
    private var brickA: LDrawGeometryBuffer {
        boxBuffer(min: SIMD3(0.016, 0.0192, 0.016), max: SIMD3(0.080, 0.0384, 0.048), colorCode: 1)
    }
    private var brickB: LDrawGeometryBuffer {
        boxBuffer(min: SIMD3(0.016, 0.0384, 0.016), max: SIMD3(0.048, 0.0576, 0.048), colorCode: 2)
    }

    private func snapshot(_ buffers: [LDrawGeometryBuffer]) -> InstructionGeometrySnapshot {
        InstructionGeometrySnapshot(buffers: buffers, bounds: nil)
    }

    private var candidates: [(index: Int, snapshot: InstructionGeometrySnapshot)] {
        [
            (0, snapshot([base])),
            (1, snapshot([base, brickA])),
            (2, snapshot([base, brickA, brickB]))
        ]
    }

    private var tableBuffer: LDrawGeometryBuffer {
        LDrawGeometryBuffer(
            colorCode: 0,
            positions: [
                SIMD3(-0.25, 0, -0.25), SIMD3(0.4, 0, -0.25), SIMD3(0.4, 0, 0.4),
                SIMD3(-0.25, 0, -0.25), SIMD3(0.4, 0, 0.4), SIMD3(-0.25, 0, 0.4)
            ],
            normals: Array(repeating: SIMD3(0, 1, 0), count: 6),
            indices: [0, 1, 2, 3, 4, 5]
        )
    }

    private func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>) -> simd_float4x4 {
        let forward = normalize(target - eye)
        let zAxis = -forward
        let xAxis = normalize(cross(SIMD3(0, 1, 0), zAxis))
        let yAxis = cross(zAxis, xAxis)
        var matrix = matrix_identity_float4x4
        matrix.columns.0 = SIMD4(xAxis, 0)
        matrix.columns.1 = SIMD4(yAxis, 0)
        matrix.columns.2 = SIMD4(zAxis, 0)
        matrix.columns.3 = SIMD4(eye, 1)
        return matrix
    }

    private func makeRenderer() throws -> ExpectedDepthRenderer {
        do {
            return try ExpectedDepthRenderer()
        } catch {
            throw XCTSkip("Metal unavailable in this test environment")
        }
    }

    /// The physical scene rendered as an observed depth frame.
    private func observedFrame(physical: [LDrawGeometryBuffer]) throws -> RegistrationFrameInput {
        let renderer = try makeRenderer()
        let worldFromCamera = lookAt(eye: SIMD3(0.30, 0.35, 0.40), target: SIMD3(0.064, 0.02, 0.032))
        let map = try renderer.render(
            snapshot: snapshot(physical + [tableBuffer]),
            viewFromModel: worldFromCamera.inverse,
            intrinsics: intrinsics,
            width: width,
            height: height
        )
        return RegistrationFrameInput(
            depth: map.depth,
            confidence: .init(repeating: 2, count: width * height),
            rawDepth: map.depth,
            rawConfidence: .init(repeating: 2, count: width * height),
            width: width,
            height: height,
            depthIntrinsics: intrinsics,
            worldFromCamera: worldFromCamera,
            timestamp: 0
        )
    }

    private func rankedScores(physical: [LDrawGeometryBuffer]) throws -> [GeometricRecoveryEstimator.CandidateScore] {
        let frame = try observedFrame(physical: physical)
        let scores = try GeometricRecoveryEstimator.scoreCandidates(
            candidates: candidates,
            frame: frame,
            coarseWorldFromModel: matrix_identity_float4x4,
            renderer: makeRenderer()
        )
        return scores.sorted { $0.score > $1.score }
    }

    func testMiddleStepWinsWhenPhysicalBuildMatchesIt() throws {
        let ranked = try rankedScores(physical: [base, brickA])
        XCTAssertEqual(ranked.first?.index, 1)
        XCTAssertTrue(GeometricRecoveryEstimator.isConclusive(
            best: ranked[0],
            runnerUp: ranked.count > 1 ? ranked[1] : nil
        ))
    }

    func testSubsetCandidateLosesToFullMatch() throws {
        // The physical build is the full ladder. Candidate 0 (just the base)
        // fits its own geometry perfectly inside it — only the unexplained
        // structure in front of it (the two bricks) tells them apart.
        let ranked = try rankedScores(physical: [base, brickA, brickB])
        XCTAssertEqual(ranked.first?.index, 2)
        let subset = try XCTUnwrap(ranked.first { $0.index == 0 })
        XCTAssertGreaterThan(subset.unexplainedFraction, 0.05, "the base-only candidate must see unexplained bricks")
    }

    func testOversizedCandidateLosesToExactMatch() throws {
        // The physical build stopped at the base; candidates with phantom
        // bricks must score below it because their extra geometry finds only
        // free space.
        let ranked = try rankedScores(physical: [base])
        XCTAssertEqual(ranked.first?.index, 0)
    }

    func testUnrelatedSceneIsInconclusive() throws {
        // Nothing brick-like on the table: no candidate may conclude.
        let ranked = try rankedScores(physical: [])
        if let best = ranked.first {
            XCTAssertFalse(GeometricRecoveryEstimator.isConclusive(
                best: best,
                runnerUp: ranked.count > 1 ? ranked[1] : nil
            ))
        }
    }
}
