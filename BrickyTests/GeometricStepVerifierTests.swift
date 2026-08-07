import XCTest
import simd
@testable import Bricky

final class GeometricStepVerifierTests: XCTestCase {
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

    /// The already-built base: 12.8 × 3.84 × 6.4 cm.
    private var completedSnapshot: InstructionGeometrySnapshot {
        InstructionGeometrySnapshot(
            buffers: [boxBuffer(min: SIMD3(0, 0, 0), max: SIMD3(0.128, 0.0384, 0.064))],
            bounds: nil
        )
    }

    /// This step's delta: a brick-sized box on top of the base.
    private func deltaBuffer(shiftX: Float = 0, height deltaHeight: Float = 0.0192) -> LDrawGeometryBuffer {
        boxBuffer(
            min: SIMD3(0.048 + shiftX, 0.0384, 0.016),
            max: SIMD3(0.080 + shiftX, 0.0384 + deltaHeight, 0.048),
            colorCode: 1
        )
    }

    private var deltaSnapshot: InstructionGeometrySnapshot {
        InstructionGeometrySnapshot(buffers: [deltaBuffer()], bounds: nil)
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

    private var worldFromCamera: simd_float4x4 {
        lookAt(eye: SIMD3(0.28, 0.40, 0.42), target: SIMD3(0.064, 0.02, 0.032))
    }

    private func lockedRegistration(timestamp: TimeInterval = 0) -> ModelRegistration {
        ModelRegistration(
            alignmentID: UUID(),
            worldFromModel: matrix_identity_float4x4,
            state: .locked,
            quality: RegistrationQuality(rmsResidual: 0.002, inlierFraction: 0.8, latticeMargin: 2.0),
            fittedStepIndex: 4,
            timestamp: timestamp
        )
    }

    /// Renders the physical scene as observed raw depth.
    private func observedFrame(
        sceneBuffers: [LDrawGeometryBuffer],
        timestamp: TimeInterval = 0
    ) throws -> RegistrationFrameInput {
        let renderer: ExpectedDepthRenderer
        do {
            renderer = try ExpectedDepthRenderer()
        } catch {
            throw XCTSkip("Metal unavailable in this test environment")
        }
        let scene = InstructionGeometrySnapshot(buffers: sceneBuffers + [tableBuffer], bounds: nil)
        let map = try renderer.render(
            snapshot: scene,
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
            timestamp: timestamp
        )
    }

    private func runVerifier(
        sceneBuffers: [LDrawGeometryBuffer],
        delta: InstructionGeometrySnapshot? = nil,
        frames: Int = 10
    ) async throws -> StepVerification {
        let verifier = try GeometricStepVerifier()
        await verifier.begin(
            stepID: "<root>#5",
            completedSnapshot: completedSnapshot,
            deltaSnapshot: delta ?? deltaSnapshot
        )
        var last: StepVerification?
        for index in 0..<frames {
            let frame = try observedFrame(sceneBuffers: sceneBuffers, timestamp: TimeInterval(index) * 0.1)
            last = try await verifier.ingest(frame: frame, registration: lockedRegistration())
        }
        return try XCTUnwrap(last)
    }

    func testCompletePlacementReadsComplete() async throws {
        let verification = try await runVerifier(
            sceneBuffers: completedSnapshot.buffers + [deltaBuffer()]
        )
        XCTAssertEqual(verification.verdict, .complete)
        XCTAssertEqual(verification.detectability, .strong)
        XCTAssertGreaterThanOrEqual(verification.framesUsed, 8)
    }

    func testMissingPlacementReadsIncomplete() async throws {
        let verification = try await runVerifier(sceneBuffers: completedSnapshot.buffers)
        XCTAssertEqual(verification.verdict, .incomplete)
    }

    func testStudOffsetPlacementReadsMisplacedWithOffset() async throws {
        let verification = try await runVerifier(
            sceneBuffers: completedSnapshot.buffers + [deltaBuffer(shiftX: 0.008)]
        )
        XCTAssertEqual(verification.verdict, .misplaced(offsetStuds: SIMD2(1, 0)))
    }

    func testFlatTileDeltaAbstainsAsUndetectable() async throws {
        let tile = InstructionGeometrySnapshot(
            buffers: [deltaBuffer(height: 0.001)],
            bounds: nil
        )
        let verification = try await runVerifier(
            sceneBuffers: completedSnapshot.buffers + [deltaBuffer(height: 0.001)],
            delta: tile
        )
        XCTAssertEqual(verification.verdict, .uncertain(.deltaUndetectable))
        XCTAssertEqual(verification.detectability, .undetectable)
    }

    func testUnlockedRegistrationRefusesToJudge() async throws {
        let verifier = try GeometricStepVerifier()
        await verifier.begin(
            stepID: "<root>#5",
            completedSnapshot: completedSnapshot,
            deltaSnapshot: deltaSnapshot
        )
        let frame = try observedFrame(sceneBuffers: completedSnapshot.buffers + [deltaBuffer()])
        var registration = lockedRegistration()
        registration = ModelRegistration(
            alignmentID: registration.alignmentID,
            worldFromModel: registration.worldFromModel,
            state: .refining,
            quality: registration.quality,
            fittedStepIndex: registration.fittedStepIndex,
            timestamp: registration.timestamp
        )
        let verification = try await verifier.ingest(frame: frame, registration: registration)
        XCTAssertEqual(verification.verdict, .uncertain(.registrationNotLocked))
    }

    func testThinEvidenceStaysUncertainAndNeverComplete() async throws {
        // Two frames are below the evidence budget even with a perfect scene.
        let verification = try await runVerifier(
            sceneBuffers: completedSnapshot.buffers + [deltaBuffer()],
            frames: 2
        )
        XCTAssertEqual(verification.verdict, .uncertain(.insufficientEvidence))
    }
}
