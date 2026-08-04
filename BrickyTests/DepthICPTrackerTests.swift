import XCTest
import simd
@testable import Bricky

/// The solver's contract is visibility-honest: directions the current view
/// constrains converge; directions it cannot see are frozen (never walked),
/// and stud-lattice aliasing is reported as a low lattice margin instead of
/// a confident lock. Full convergence is a multi-view property — the user
/// moves, each view pulls the faces it sees — which the actor-level test
/// exercises with two viewpoints.
final class DepthICPTrackerTests: XCTestCase {
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

    /// A build-scale L-shaped stack (13 cm base), distinctive under 180° yaw.
    private var lShapeSnapshot: InstructionGeometrySnapshot {
        InstructionGeometrySnapshot(
            buffers: [
                boxBuffer(min: SIMD3(0, 0, 0), max: SIMD3(0.128, 0.0384, 0.064)),
                boxBuffer(min: SIMD3(0, 0.0384, 0), max: SIMD3(0.064, 0.0768, 0.064), colorCode: 1)
            ],
            bounds: nil
        )
    }

    private var plainBoxSnapshot: InstructionGeometrySnapshot {
        InstructionGeometrySnapshot(
            buffers: [boxBuffer(min: SIMD3(0, 0, 0), max: SIMD3(0.128, 0.0384, 0.064))],
            bounds: nil
        )
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

    /// Ground-truth depth of the snapshot (plus tabletop) at world identity,
    /// wrapped as a full-confidence tracker frame.
    private func syntheticFrame(
        snapshot: InstructionGeometrySnapshot,
        worldFromCamera: simd_float4x4,
        timestamp: TimeInterval = 0
    ) throws -> RegistrationFrameInput {
        let renderer: ExpectedDepthRenderer
        do {
            renderer = try ExpectedDepthRenderer()
        } catch {
            throw XCTSkip("Metal unavailable in this test environment")
        }
        let scene = InstructionGeometrySnapshot(buffers: snapshot.buffers + [tableBuffer], bounds: nil)
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
            rawDepth: nil,
            rawConfidence: nil,
            width: width,
            height: height,
            depthIntrinsics: intrinsics,
            worldFromCamera: worldFromCamera,
            timestamp: timestamp
        )
    }

    private func pose(x: Float, z: Float, yawDegrees: Float) -> simd_float4x4 {
        let yaw = yawDegrees * .pi / 180
        var matrix = matrix_identity_float4x4
        matrix.columns.0 = SIMD4(cos(yaw), 0, -sin(yaw), 0)
        matrix.columns.2 = SIMD4(sin(yaw), 0, cos(yaw), 0)
        matrix.columns.3 = SIMD4(x, 0, z, 1)
        return matrix
    }

    private func yawDegrees(of matrix: simd_float4x4) -> Float {
        atan2(-matrix.columns.0.z, matrix.columns.0.x) * 180 / .pi
    }

    private let modelCenter = SIMD3<Float>(0.064, 0, 0.032)
    /// Camera on the model's +x side, oblique, seeing top, +x and +z faces.
    private var viewFromPlusX: simd_float4x4 { lookAt(eye: SIMD3(0.30, 0.35, 0.40), target: modelCenter) }
    /// Camera on the -x side, seeing top, -x and +z faces.
    private var viewFromMinusX: simd_float4x4 { lookAt(eye: SIMD3(-0.17, 0.35, 0.40), target: modelCenter) }

    func testSingleViewConvergesVisibleDirectionsWithoutDrift() throws {
        let frame = try syntheticFrame(snapshot: lShapeSnapshot, worldFromCamera: viewFromPlusX)
        let sample = ModelSurfaceSampler.sample(lShapeSnapshot, stepIndex: 0)

        // The -x offset is visible from a +x-side camera (predicted face
        // inside the true one); z and yaw are visible from the +z/top faces.
        let result = DepthICPTracker.solve(
            sample: sample,
            frame: frame,
            initialWorldFromModel: pose(x: -0.004, z: -0.005, yawDegrees: 5)
        )
        let translation = result.worldFromModel.columns.3
        XCTAssertEqual(translation.x, 0, accuracy: 0.002)
        XCTAssertEqual(translation.y, 0, accuracy: 0.002)
        XCTAssertEqual(translation.z, 0, accuracy: 0.002)
        XCTAssertEqual(yawDegrees(of: result.worldFromModel), 0, accuracy: 1.5)
        XCTAssertLessThanOrEqual(result.quality.rmsResidual, 0.004)
        XCTAssertGreaterThanOrEqual(result.quality.inlierFraction, 0.6)
    }

    func testFullStudOffsetRecoversFromObliqueView() throws {
        let frame = try syntheticFrame(snapshot: lShapeSnapshot, worldFromCamera: viewFromPlusX)
        let sample = ModelSurfaceSampler.sample(lShapeSnapshot, stepIndex: 0)

        let result = DepthICPTracker.solve(
            sample: sample,
            frame: frame,
            initialWorldFromModel: pose(x: 0.008, z: 0, yawDegrees: 0)
        )
        XCTAssertEqual(result.worldFromModel.columns.3.x, 0, accuracy: 0.002)
        XCTAssertGreaterThanOrEqual(result.quality.latticeMargin, 1.3)
    }

    func testBlindViewNeverRunsAwayAndNeverFakesALock() throws {
        // Near-top-down: side faces are grazing-rejected, so lateral offsets
        // are (close to) unobservable. The contract is composite: the solver
        // must not end farther from truth than it started plus slack, and if
        // the stud offset was not recovered it must not read as a lock —
        // the shifted-lattice alternative explains the depth equally well.
        let topDown = lookAt(eye: SIMD3(0.064, 0.45, 0.10), target: modelCenter)
        let frame = try syntheticFrame(snapshot: lShapeSnapshot, worldFromCamera: topDown)
        let sample = ModelSurfaceSampler.sample(lShapeSnapshot, stepIndex: 0)

        let result = DepthICPTracker.solve(
            sample: sample,
            frame: frame,
            initialWorldFromModel: pose(x: 0.008, z: 0, yawDegrees: 0)
        )
        let finalX = result.worldFromModel.columns.3.x
        XCTAssertLessThanOrEqual(abs(finalX), 0.012, "must never end farther from truth than init plus slack")
        if abs(finalX) > 0.004 {
            XCTAssertLessThan(
                result.quality.latticeMargin, 1.3,
                "an unrecovered stud offset must not report a confident lock"
            )
        }
    }

    func testPlainBoxIsFlaggedAmbiguousUnderHalfTurn() throws {
        let frame = try syntheticFrame(snapshot: plainBoxSnapshot, worldFromCamera: viewFromPlusX)
        let sample = ModelSurfaceSampler.sample(plainBoxSnapshot, stepIndex: 0)

        let result = DepthICPTracker.solve(
            sample: sample,
            frame: frame,
            initialWorldFromModel: pose(x: -0.003, z: -0.002, yawDegrees: 2)
        )
        // A 180°-symmetric box genuinely cannot be disambiguated by depth;
        // the margin must say so instead of pretending a lock.
        XCTAssertLessThan(result.quality.latticeMargin, 1.3)
        XCTAssertGreaterThanOrEqual(result.quality.inlierFraction, 0.6)
    }

    func testSolverReportsNothingUsableOnEmptyDepth() throws {
        let sample = ModelSurfaceSampler.sample(lShapeSnapshot, stepIndex: 0)
        let frame = RegistrationFrameInput(
            depth: .init(repeating: 0, count: width * height),
            confidence: .init(repeating: 2, count: width * height),
            rawDepth: nil,
            rawConfidence: nil,
            width: width,
            height: height,
            depthIntrinsics: intrinsics,
            worldFromCamera: viewFromPlusX,
            timestamp: 0
        )
        let result = DepthICPTracker.solve(
            sample: sample,
            frame: frame,
            initialWorldFromModel: matrix_identity_float4x4
        )
        XCTAssertEqual(result.quality.inlierFraction, 0)
    }

    func testTrackerLocksAcrossTwoViewpoints() async throws {
        let sample = ModelSurfaceSampler.sample(lShapeSnapshot, stepIndex: 7)
        let plusX = try syntheticFrame(snapshot: lShapeSnapshot, worldFromCamera: viewFromPlusX)
        let minusX = try syntheticFrame(snapshot: lShapeSnapshot, worldFromCamera: viewFromMinusX)

        let tracker = DepthICPTracker()
        let alignmentID = UUID()
        // +6 mm x is unobservable from the +x view alone; the -x view pulls
        // it home. This is the product's actual geometry: the user moves.
        await tracker.setTarget(
            sample,
            coarseWorldFromModel: pose(x: 0.006, z: -0.004, yawDegrees: 4),
            alignmentID: alignmentID
        )

        let frames = AsyncStream<RegistrationFrameInput> { continuation in
            for index in 0..<16 {
                let base = index.isMultiple(of: 2) ? plusX : minusX
                continuation.yield(RegistrationFrameInput(
                    depth: base.depth,
                    confidence: base.confidence,
                    rawDepth: nil,
                    rawConfidence: nil,
                    width: base.width,
                    height: base.height,
                    depthIntrinsics: base.depthIntrinsics,
                    worldFromCamera: base.worldFromCamera,
                    timestamp: TimeInterval(index) * 0.1
                ))
            }
            continuation.finish()
        }

        var updates: [ModelRegistration] = []
        for await update in await tracker.track(frames: frames) {
            updates.append(update)
        }

        let last = try XCTUnwrap(updates.last)
        XCTAssertEqual(last.state, .locked)
        XCTAssertEqual(last.alignmentID, alignmentID)
        XCTAssertEqual(last.fittedStepIndex, 7)
        XCTAssertTrue(last.allowsVerification)
        XCTAssertEqual(last.worldFromModel.columns.3.x, 0, accuracy: 0.002)
        XCTAssertEqual(last.worldFromModel.columns.3.z, 0, accuracy: 0.002)
        XCTAssertEqual(yawDegrees(of: last.worldFromModel), 0, accuracy: 1.5)
    }
}
