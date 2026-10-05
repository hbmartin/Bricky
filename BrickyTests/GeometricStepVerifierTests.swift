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

    /// Every judge must pass the same verdict contract. The geometric
    /// verifier is the oracle; the shadow build diff (M2.3) joins it here.
    private var judges: [(name: String, make: () throws -> any StepJudging)] {
        [("verifier", { try GeometricStepVerifier() })]
    }

    /// The step as a two-placement plan: the base, then the delta.
    private func stepGeometry(delta: InstructionGeometrySnapshot) -> StepGeometry {
        let segments = SegmentedGeometry(segments: [completedSnapshot.buffers, delta.buffers])
        return StepGeometry(
            completedSnapshot: completedSnapshot, deltaSnapshot: delta, segments: segments,
            index: PlacementGeometryIndex.build(transforms: [LDrawTransform(), LDrawTransform()], segments: segments),
            completedPlacements: 0..<1, deltaPlacements: 1..<2
        )
    }

    private func runVerifier(
        judge make: () throws -> any StepJudging,
        sceneBuffers: [LDrawGeometryBuffer],
        delta: InstructionGeometrySnapshot? = nil,
        frames: Int = 10
    ) async throws -> StepVerification {
        let judge = try make()
        await judge.begin(stepID: "<root>#5", geometry: stepGeometry(delta: delta ?? deltaSnapshot))
        var last: StepVerification?
        for index in 0..<frames {
            let frame = try observedFrame(sceneBuffers: sceneBuffers, timestamp: TimeInterval(index) * 0.1)
            last = try await judge.ingest(frame: frame, registration: lockedRegistration())
        }
        return try XCTUnwrap(last)
    }

    /// A window recorded on device must replay to the verdict the device
    /// published: planes, poses and registration survive the round trip.
    func testRecordedWindowReplaysToTheSameVerdict() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("window-replay-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = RecoveryEvidenceRecorder(
            root: root, instructionSHA256: String(repeating: "0", count: 64), authoredModelID: UUID(),
            modelTitle: "Window", stepCount: 5, staged: nil
        )
        let verifier = try GeometricStepVerifier()
        await verifier.begin(stepID: "<root>#5", completedSnapshot: completedSnapshot, deltaSnapshot: deltaSnapshot)
        var samples: [VerificationWindowSample] = []
        var published: StepVerification?
        for index in 0..<8 {
            let frame = try observedFrame(
                sceneBuffers: completedSnapshot.buffers + [deltaBuffer(shiftX: 0.008)],
                timestamp: TimeInterval(index) * 0.1
            )
            let registration = lockedRegistration(timestamp: frame.timestamp)
            let result = try await verifier.ingest(frame: frame, registration: registration)
            samples.append(VerificationWindowSample(
                frameID: UUID(), frame: frame, registration: registration, result: result, ingestMilliseconds: 1
            ))
            published = result
        }
        let devicePublished = try XCTUnwrap(published)
        let windowID = UUID()
        await recorder.record(VerificationWindowCapture(
            windowID: windowID, stepID: "<root>#5", stepIndex: 4, trigger: .verdictChange, samples: samples,
            verification: devicePublished, staged: nil, ingestMillisecondsSinceBegin: 8, createdAt: .now
        ))

        let sessionDirectory = root
            .appendingPathComponent(RecoveryEvidenceRecorder.directoryName)
            .appendingPathComponent(recorder.sessionID.uuidString)
        let decoder = EvidenceSchema.decoder()
        let window = try decoder.decode(
            VerificationWindowRecord.self,
            from: Data(contentsOf: sessionDirectory.appendingPathComponent("windows/\(windowID.uuidString).json"))
        )
        XCTAssertEqual(window.verdict, devicePublished.verdict.evidenceName)
        let replay = try GeometricStepVerifier()
        await replay.begin(stepID: "<root>#5", completedSnapshot: completedSnapshot, deltaSnapshot: deltaSnapshot)
        var replayed: StepVerification?
        for frame in window.frames {
            let record = try decoder.decode(
                EvidenceDepthFrameRecord.self,
                from: Data(contentsOf: sessionDirectory.appendingPathComponent("windows/frames/\(frame.frameID.uuidString).json"))
            )
            let planes = try EvidenceDepthPlanes.load(record, in: sessionDirectory)
            replayed = try await replay.ingest(
                frame: RegistrationFrameInput(record: record, planes: planes),
                registration: ModelRegistration(windowFrame: frame, stepIndex: 4, timestamp: record.timestamp)
            )
        }
        XCTAssertEqual(replayed?.verdict, devicePublished.verdict)
        XCTAssertEqual(replayed?.deltaPixels, devicePublished.deltaPixels)
    }

    func testCompletePlacementReadsComplete() async throws {
        for judge in judges {
            let verification = try await runVerifier(
                judge: judge.make, sceneBuffers: completedSnapshot.buffers + [deltaBuffer()]
            )
            XCTAssertEqual(verification.verdict, .complete, judge.name)
            XCTAssertEqual(verification.detectability, .strong, judge.name)
            XCTAssertGreaterThanOrEqual(verification.framesUsed, 8, judge.name)
        }
    }

    func testMissingPlacementReadsIncomplete() async throws {
        for judge in judges {
            let verification = try await runVerifier(judge: judge.make, sceneBuffers: completedSnapshot.buffers)
            XCTAssertEqual(verification.verdict, .incomplete, judge.name)
        }
    }

    func testStudOffsetPlacementReadsMisplacedWithOffset() async throws {
        for judge in judges {
            let verification = try await runVerifier(
                judge: judge.make, sceneBuffers: completedSnapshot.buffers + [deltaBuffer(shiftX: 0.008)]
            )
            XCTAssertEqual(verification.verdict, .misplaced(offsetStuds: SIMD2(1, 0)), judge.name)
        }
    }

    func testFlatTileDeltaAbstainsAsUndetectable() async throws {
        let tile = InstructionGeometrySnapshot(buffers: [deltaBuffer(height: 0.001)], bounds: nil)
        for judge in judges {
            let verification = try await runVerifier(
                judge: judge.make, sceneBuffers: completedSnapshot.buffers + [deltaBuffer(height: 0.001)], delta: tile
            )
            XCTAssertEqual(verification.verdict, .uncertain(.deltaUndetectable), judge.name)
            XCTAssertEqual(verification.detectability, .undetectable, judge.name)
        }
    }

    func testUnlockedRegistrationRefusesToJudge() async throws {
        let frame = try observedFrame(sceneBuffers: completedSnapshot.buffers + [deltaBuffer()])
        let locked = lockedRegistration()
        let refining = ModelRegistration(
            alignmentID: locked.alignmentID, worldFromModel: locked.worldFromModel, state: .refining,
            quality: locked.quality, fittedStepIndex: locked.fittedStepIndex, timestamp: locked.timestamp
        )
        for judge in judges {
            let judging = try judge.make()
            await judging.begin(stepID: "<root>#5", geometry: stepGeometry(delta: deltaSnapshot))
            let verification = try await judging.ingest(frame: frame, registration: refining)
            XCTAssertEqual(verification.verdict, .uncertain(.registrationNotLocked), judge.name)
        }
    }

    func testThinEvidenceStaysUncertainAndNeverComplete() async throws {
        // Two frames are below the evidence budget even with a perfect scene.
        for judge in judges {
            let verification = try await runVerifier(
                judge: judge.make, sceneBuffers: completedSnapshot.buffers + [deltaBuffer()], frames: 2
            )
            XCTAssertEqual(verification.verdict, .uncertain(.insufficientEvidence), judge.name)
        }
    }
}
