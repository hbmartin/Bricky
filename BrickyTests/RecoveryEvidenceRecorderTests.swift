import RecoveryMLX
import XCTest
import simd
@testable import Bricky

final class RecoveryEvidenceRecorderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("evidence-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testSessionRoundTripThroughRecorder() async throws {
        let recorder = makeRecorder()
        let capture = try makeCapture()
        await recorder.recordCaptures([capture])

        let board = root.appendingPathComponent("board.jpg")
        try Data("jpeg-bytes".utf8).write(to: board)
        await recorder.recordPass(
            pass: .broad,
            passIndex: 0,
            capture: capture,
            candidates: [
                .init(slot: "A", stepIndex: -1, stepID: "step-zero", jpegData: Data("tile-a".utf8)),
                .init(slot: "B", stepIndex: 3, stepID: "step-3", jpegData: Data("tile-b".utf8))
            ],
            boardURL: board,
            prompt: "rank prompt",
            trace: makeTrace()
        )
        await recorder.finalize(
            estimate: nil,
            analysisError: "model exploded",
            groundTruth: EvidenceGroundTruth(kind: .confirmed, expectedCompletedCount: 4, confirmedAt: .now)
        )

        let sessionDirectory = root
            .appendingPathComponent(RecoveryEvidenceRecorder.directoryName)
            .appendingPathComponent(recorder.sessionID.uuidString)
        let session = try EvidenceSchema.decoder().decode(
            EvidenceSessionFile.self,
            from: Data(contentsOf: sessionDirectory.appendingPathComponent("session.json"))
        )
        XCTAssertEqual(session.sessionVersion, EvidenceSchema.sessionVersion)
        XCTAssertEqual(session.captures.map(\.captureID), [capture.id])
        XCTAssertEqual(session.groundTruth.kind, .confirmed)
        XCTAssertEqual(session.groundTruth.expectedCompletedCount, 4)
        XCTAssertEqual(session.analysisError, "model exploded")

        let rows = try loadTraceRows(sessionDirectory: sessionDirectory)
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.pass, .broad)
        XCTAssertEqual(row.rawOutput, #"{"status":"matched","ranking":["B"]}"#)
        XCTAssertEqual(row.termination, "accepted")
        XCTAssertEqual(row.candidateStepIndices, ["A": -1, "B": 3])
        XCTAssertEqual(row.candidateStepIDs, ["A": "step-zero", "B": "step-3"])

        // The recorder copies: originals and copies both exist.
        XCTAssertTrue(FileManager.default.fileExists(atPath: board.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: sessionDirectory.appendingPathComponent(row.boardRelativePath).path
        ))
        for relative in row.tileRelativePaths.values {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: sessionDirectory.appendingPathComponent(relative).path
            ))
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: sessionDirectory.appendingPathComponent("captures/\(capture.id.uuidString).jpg").path
        ))
    }

    func testCaptureRecordsTheLockedModelPoseAndCheckGeometry() async throws {
        let recorder = makeRecorder()
        let capture = try makeCapture()
        var pose = matrix_identity_float4x4
        pose.columns.3 = SIMD4(0.1, -0.2, -0.45, 1)
        await recorder.recordCaptures([capture], worldFromModel: pose)
        let board = root.appendingPathComponent("board.jpg")
        try Data("jpeg-bytes".utf8).write(to: board)
        let geometry = CheckGeometryRecord(
            deltaBox: .init(x: 0.25, y: 0.5, width: 0.125, height: 0.25), deltaPixels: 42, gridWidth: 256, gridHeight: 192
        )
        await recorder.recordPass(
            pass: .check, passIndex: 0, capture: capture,
            candidates: [.init(slot: "A", stepIndex: 0, stepID: "m#1", jpegData: Data("tile".utf8))],
            boardURL: board, prompt: "check prompt", trace: makeTrace(), checkGeometry: geometry
        )
        await recorder.finalize(estimate: nil, analysisError: nil, groundTruth: .unlabeled)

        let sessionDirectory = root
            .appendingPathComponent(RecoveryEvidenceRecorder.directoryName)
            .appendingPathComponent(recorder.sessionID.uuidString)
        let session = try EvidenceSchema.decoder().decode(
            EvidenceSessionFile.self,
            from: Data(contentsOf: sessionDirectory.appendingPathComponent("session.json"))
        )
        // Column-major, the same layout as camera_transform: the translation
        // is the last four floats.
        let recorded = try XCTUnwrap(session.captures.first?.worldFromModel)
        XCTAssertEqual(Array(recorded[12..<16]), [0.1, -0.2, -0.45, 1])
        XCTAssertEqual(try loadTraceRows(sessionDirectory: sessionDirectory).first?.checkGeometry, geometry)

        // Captures recorded without a lock carry no pose.
        let unlocked = makeRecorder()
        await unlocked.recordCaptures([try makeCapture()])
        await unlocked.finalize(estimate: nil, analysisError: nil, groundTruth: .unlabeled)
        let unlockedSession = try EvidenceSchema.decoder().decode(
            EvidenceSessionFile.self,
            from: Data(contentsOf: root
                .appendingPathComponent(RecoveryEvidenceRecorder.directoryName)
                .appendingPathComponent(unlocked.sessionID.uuidString)
                .appendingPathComponent("session.json"))
        )
        XCTAssertNil(unlockedSession.captures.first?.worldFromModel)
    }

    func testTraceRowsUseSnakeCaseKeys() async throws {
        let recorder = makeRecorder()
        let board = root.appendingPathComponent("board.jpg")
        try Data("jpeg".utf8).write(to: board)
        await recorder.recordPass(
            pass: .finalist, passIndex: 2, capture: nil,
            candidates: [.init(slot: "A", stepIndex: 0, stepID: "s", jpegData: nil)],
            boardURL: board, prompt: "p", trace: makeTrace()
        )
        let sessionDirectory = root
            .appendingPathComponent(RecoveryEvidenceRecorder.directoryName)
            .appendingPathComponent(recorder.sessionID.uuidString)
        let raw = try String(contentsOf: sessionDirectory.appendingPathComponent("traces.ndjson"), encoding: .utf8)
        for key in ["trace_id", "session_id", "pass_index", "board_relative_path", "raw_output", "latency_ms", "schema_json", "created_at"] {
            XCTAssertTrue(raw.contains("\"\(key)\""), "missing key \(key) in \(raw)")
        }
    }

    func testFitRecordsGoToTheirOwnFileNotTracesNdjson() async throws {
        let recorder = makeRecorder()
        await recorder.recordFits([
            makeFit(sessionID: recorder.sessionID, candidateIndex: 0, conclusive: false),
            makeFit(sessionID: recorder.sessionID, candidateIndex: 3, conclusive: true),
        ])
        let sessionDirectory = root
            .appendingPathComponent(RecoveryEvidenceRecorder.directoryName)
            .appendingPathComponent(recorder.sessionID.uuidString)

        // "Evidence Trace" means one VLM inference call; a geometric fit is
        // not one, so it must never land in traces.ndjson.
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: sessionDirectory.appendingPathComponent("traces.ndjson").path)
        )
        let loaded = await recorder.loadFitRecords()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.map(\.candidateIndex), [0, 3])
        XCTAssertEqual(loaded.filter(\.conclusive).count, 1)

        let raw = try String(contentsOf: sessionDirectory.appendingPathComponent("fits.ndjson"), encoding: .utf8)
        for key in ["fit_version", "candidate_index", "phantom_fraction", "world_from_model", "disqualification"] {
            XCTAssertTrue(raw.contains("\"\(key)\""), "missing key \(key) in \(raw)")
        }
    }

    func testRecordingNoFitsWritesNothing() async throws {
        let recorder = makeRecorder()
        await recorder.recordFits([])
        // An empty call must not even create the session directory: a VLM-only
        // recovery has no geometric evidence and should leave no trace of one.
        let sessionDirectory = root
            .appendingPathComponent(RecoveryEvidenceRecorder.directoryName)
            .appendingPathComponent(recorder.sessionID.uuidString)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: sessionDirectory.appendingPathComponent("fits.ndjson").path)
        )
        // Not just fits.ndjson: no session.json or any other evidence either.
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDirectory.path))
    }

    func testDepthFramePlanesRoundTripByteForByte() async throws {
        let recorder = makeRecorder()
        let captureID = UUID()
        let width = 4
        let height = 3
        let depth = (0..<(width * height)).map { Float32($0) * 0.01 }
        let confidence = [UInt8](repeating: 2, count: width * height)
        let rawDepth = depth.map { $0 + 0.005 }
        var intrinsics = matrix_identity_float3x3
        intrinsics[0][0] = 210
        intrinsics[2][0] = 128
        var pose = matrix_identity_float4x4
        pose.columns.3 = SIMD4(0.1, 0.2, 0.3, 1)

        await recorder.recordDepthFrame(
            RegistrationFrameInput(
                depth: depth,
                confidence: confidence,
                rawDepth: rawDepth,
                rawConfidence: confidence,
                width: width,
                height: height,
                depthIntrinsics: intrinsics,
                worldFromCamera: pose,
                timestamp: 42.5
            ),
            captureID: captureID,
            coarseWorldFromModel: matrix_identity_float4x4
        )

        let sessionDirectory = root
            .appendingPathComponent(RecoveryEvidenceRecorder.directoryName)
            .appendingPathComponent(recorder.sessionID.uuidString)
        let frames = await recorder.loadDepthFrames()
        let record = try XCTUnwrap(frames.first)
        XCTAssertEqual(record.captureID, captureID)
        XCTAssertEqual(record.width, width)
        XCTAssertEqual(record.timestamp, 42.5)
        // Row-major, so translation lands at 3/7/11 rather than in a column.
        XCTAssertEqual(record.worldFromCamera[3], 0.1, accuracy: 1e-6)
        XCTAssertEqual(record.worldFromCamera[7], 0.2, accuracy: 1e-6)
        XCTAssertNotNil(record.rawDepthRelativePath)

        // The plane is the whole point: it must reload to the exact array,
        // because a corpus is collected once and replayed for years.
        let reloaded = try Data(contentsOf: sessionDirectory.appendingPathComponent(record.depthRelativePath))
            .withUnsafeBytes { Array($0.bindMemory(to: Float32.self)) }
        XCTAssertEqual(reloaded, depth)
        XCTAssertEqual(
            try Data(contentsOf: sessionDirectory.appendingPathComponent(record.depthRelativePath)).count,
            record.expectedBytes(elementSize: MemoryLayout<Float32>.size)
        )
    }

    func testDepthFrameWithoutARawVariantOmitsThosePlanes() async throws {
        let recorder = makeRecorder()
        await recorder.recordDepthFrame(
            RegistrationFrameInput(
                depth: [Float32](repeating: 1, count: 6),
                confidence: [UInt8](repeating: 1, count: 6),
                rawDepth: nil,
                rawConfidence: nil,
                width: 3,
                height: 2,
                depthIntrinsics: matrix_identity_float3x3,
                worldFromCamera: matrix_identity_float4x4,
                timestamp: 1
            ),
            captureID: UUID(),
            coarseWorldFromModel: matrix_identity_float4x4
        )
        let frames = await recorder.loadDepthFrames()
        let record = try XCTUnwrap(frames.first)
        XCTAssertNil(record.rawDepthRelativePath)
        XCTAssertNil(record.rawConfidenceRelativePath)
    }

    // Fails on the old code by not compiling: the recorder kept no alignment,
    // so no recovery could be replayed from its bundle.
    func testRecoveryInputsPutTheAlignmentBesideTheCenterDepthFrame() async throws {
        let recorder = makeRecorder()
        // Left first, so "the first capture" is not the center one.
        let captures = try [CaptureAngle.left, .center, .right].map { try makeCapture(angle: $0) }
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4(0.1, 0.2, 0.3, 1)
        let alignment = ARAlignment(id: UUID(), transform: transform, isTracking: true)
        await recorder.recordRecoveryInputs(
            captures: captures,
            depthFrame: RegistrationFrameInput(
                depth: [Float32](repeating: 1, count: 6), confidence: [UInt8](repeating: 2, count: 6),
                rawDepth: nil, rawConfidence: nil, width: 3, height: 2,
                depthIntrinsics: matrix_identity_float3x3, worldFromCamera: matrix_identity_float4x4, timestamp: 1
            ),
            alignment: alignment
        )

        let frames = await recorder.loadDepthFrames()
        let record = try XCTUnwrap(frames.first)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(record.captureID, captures[1].id)
        // Row-major like world_from_camera: translation at 3, 7 and 11.
        let coarse = try XCTUnwrap(record.coarseWorldFromModel)
        XCTAssertEqual(coarse.count, 16)
        XCTAssertEqual(coarse[3], 0.1)
        XCTAssertEqual(coarse[7], 0.2)
        XCTAssertEqual(coarse[11], 0.3)
        XCTAssertEqual(coarse[15], 1)

        let sessionDirectory = root
            .appendingPathComponent(RecoveryEvidenceRecorder.directoryName)
            .appendingPathComponent(recorder.sessionID.uuidString)
        let session = try EvidenceSchema.decoder().decode(
            EvidenceSessionFile.self,
            from: Data(contentsOf: sessionDirectory.appendingPathComponent("session.json"))
        )
        XCTAssertEqual(session.captures.map(\.captureID), captures.map(\.id))
        XCTAssertEqual(session.partPackVersion, LDrawPartPackManager.version)

        // Without a depth frame only the captures are recorded.
        let photosOnly = makeRecorder()
        await photosOnly.recordRecoveryInputs(captures: captures, depthFrame: nil, alignment: alignment)
        let none = await photosOnly.loadDepthFrames()
        XCTAssertTrue(none.isEmpty)
    }

    // Fails on the old code by not compiling: the relay's extraction cost and
    // the segmentation buffer's shape were measured nowhere, so Phase 1's
    // "p95 ≤ 3 ms" and "record the buffer's size" had no readout.
    func testWindowFrameSidecarRecordsAuxiliaryExtractTime() async throws {
        let recorder = makeRecorder()
        func frame(timed: Bool) -> RegistrationFrameInput {
            RegistrationFrameInput(
                depth: [Float32](repeating: 1, count: 6), confidence: [UInt8](repeating: 2, count: 6),
                rawDepth: nil, rawConfidence: nil, width: 3, height: 2,
                depthIntrinsics: matrix_identity_float3x3, worldFromCamera: matrix_identity_float4x4, timestamp: 1,
                auxiliaryExtractMilliseconds: timed ? 1.25 : nil,
                segmentationWidth: timed ? 256 : nil, segmentationHeight: timed ? 192 : nil,
                segmentationBytesPerRow: timed ? 320 : nil
            )
        }
        try await recorder.writeDepthFrame(frame(timed: true), id: UUID(), stem: "windows/frames/timed")
        try await recorder.writeDepthFrame(frame(timed: false), id: UUID(), stem: "windows/frames/untimed")
        let directory = root
            .appendingPathComponent(RecoveryEvidenceRecorder.directoryName)
            .appendingPathComponent(recorder.sessionID.uuidString)
            .appendingPathComponent("windows/frames")
        func sidecar(_ name: String) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(
                with: Data(contentsOf: directory.appendingPathComponent("\(name).json"))
            ) as? [String: Any])
        }
        let timed = try sidecar("timed")
        XCTAssertEqual(timed["auxiliary_extract_ms"] as? Double, 1.25)
        XCTAssertEqual(timed["segmentation_width"] as? Int, 256)
        XCTAssertEqual(timed["segmentation_height"] as? Int, 192)
        XCTAssertEqual(timed["segmentation_bytes_per_row"] as? Int, 320)
        let untimed = try sidecar("untimed")
        for key in ["auxiliary_extract_ms", "segmentation_width", "segmentation_height", "segmentation_bytes_per_row"] {
            XCTAssertNil(untimed[key], "\(key) must be absent when nothing was measured")
        }
    }

    // Fails on the old code by behaviour: it wrote whatever it was handed, so
    // an 11-float depth plane landed beside a 4x3 sidecar that `validate()`
    // then reported, refusing the whole bundle to every replay.
    func testAFrameWhosePlanesDoNotFillItsGridIsNotRecorded() async throws {
        let recorder = makeRecorder()
        await recorder.recordDepthFrame(
            RegistrationFrameInput(
                depth: [Float32](repeating: 1, count: 11),
                confidence: [UInt8](repeating: 1, count: 12),
                rawDepth: nil,
                rawConfidence: nil,
                width: 4,
                height: 3,
                depthIntrinsics: matrix_identity_float3x3,
                worldFromCamera: matrix_identity_float4x4,
                timestamp: 1
            ),
            captureID: UUID(),
            coarseWorldFromModel: matrix_identity_float4x4
        )
        let frames = await recorder.loadDepthFrames()
        XCTAssertTrue(frames.isEmpty)
    }

    func testFramesAndCapturesRecordRunnerUp() async throws {
        let recorder = makeRecorder()
        let samples = [
            windowSample(timestamp: 0, runnerUp: .shiftZPositive),
            windowSample(timestamp: 1),
        ]
        await recorder.record(windowCapture(samples: samples, trigger: .confirm, staged: nil))
        // The photo-check path: the capture is recorded inside the check,
        // then stamped with the registration it was taken under.
        let capture = try makeCapture()
        await recorder.recordCaptures([capture], worldFromModel: matrix_identity_float4x4)
        await recorder.annotateCapture(id: capture.id, registration: ModelRegistration(
            alignmentID: UUID(), worldFromModel: matrix_identity_float4x4, state: .ambiguous,
            quality: RegistrationQuality(rmsResidual: 0.002, inlierFraction: 0.8, latticeMargin: 1.125, latticeRunnerUp: .yaw180),
            fittedStepIndex: 2, timestamp: 0
        ))
        // An unknown capture, or no registration, changes nothing.
        await recorder.annotateCapture(id: UUID(), registration: nil)
        await recorder.finalize(estimate: nil, analysisError: nil, groundTruth: .unlabeled)

        let sessionDirectory = root
            .appendingPathComponent(RecoveryEvidenceRecorder.directoryName)
            .appendingPathComponent(recorder.sessionID.uuidString)
        let windowURL = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: sessionDirectory.appendingPathComponent("windows"), includingPropertiesForKeys: nil
        ).first { $0.pathExtension == "json" })
        let window = try EvidenceSchema.decoder().decode(VerificationWindowRecord.self, from: Data(contentsOf: windowURL))
        XCTAssertEqual(window.frames.map(\.latticeRunnerUp), ["shift_z_pos", nil])

        let session = try EvidenceSchema.decoder().decode(
            EvidenceSessionFile.self,
            from: Data(contentsOf: sessionDirectory.appendingPathComponent("session.json"))
        )
        let record = try XCTUnwrap(session.captures.first)
        XCTAssertEqual(record.registrationState, "ambiguous")
        XCTAssertEqual(record.latticeMargin, 1.125)
        XCTAssertEqual(record.latticeRunnerUp, "yaw_180")
    }

    func testWindowRecordsLatticeContests() async throws {
        let recorder = makeRecorder()
        var verification = verificationResult(.misplaced(offsetStuds: SIMD2(1, 0)), timestamp: 0)
        verification.latticeContests = [
            LatticeContest(offsetStuds: SIMD2(1, 0), winsComplete: 3, winsShifted: 11),
            LatticeContest(offsetStuds: SIMD2(0, -1), winsComplete: 7, winsShifted: 0),
        ]
        await recorder.record(VerificationWindowCapture(
            windowID: UUID(), stepID: "main.ldr#3", stepIndex: 2, trigger: .confirm,
            samples: [windowSample(timestamp: 0)], verification: verification,
            staged: nil, ingestMillisecondsSinceBegin: 70, createdAt: .now
        ))

        let sessionDirectory = root
            .appendingPathComponent(RecoveryEvidenceRecorder.directoryName)
            .appendingPathComponent(recorder.sessionID.uuidString)
        let windowURL = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: sessionDirectory.appendingPathComponent("windows"), includingPropertiesForKeys: nil
        ).first { $0.pathExtension == "json" })
        let window = try EvidenceSchema.decoder().decode(VerificationWindowRecord.self, from: Data(contentsOf: windowURL))
        XCTAssertEqual(window.latticeContests, [
            LatticeContestRecord(offsetStuds: [1, 0], winsComplete: 3, winsShifted: 11),
            LatticeContestRecord(offsetStuds: [0, -1], winsComplete: 7, winsShifted: 0),
        ])
    }

    func testPlacementRecordKeepsTallies() {
        let observation = PlacementObservation(
            placement: 4,
            state: .displaced(LatticeOffset(dx: 1)),
            evidence: PlacementEvidence(support: 12, absence: 3, tallies: [
                HypothesisTally(offset: LatticeOffset(dx: 1), winsPresent: 2, winsAlternative: 9),
                HypothesisTally(offset: LatticeOffset(quarterTurns: 1), winsPresent: 5, winsAlternative: 1),
            ])
        )
        let record = RecoveryEvidenceRecorder.placementRecord(observation)
        XCTAssertEqual(record.tallies, [
            HypothesisTallyRecord(offset: [1, 0, 0, 0], winsPresent: 2, winsAlternative: 9),
            HypothesisTallyRecord(offset: [0, 0, 0, 1], winsPresent: 5, winsAlternative: 1),
        ])
        let bare = RecoveryEvidenceRecorder.placementRecord(PlacementObservation(
            placement: 1, state: .present, evidence: PlacementEvidence(support: 4)
        ))
        XCTAssertNil(bare.tallies, "no contest, no field")
    }

    func testStagedPhysicalSessionsCarryTheirBuildLabel() async throws {
        let suite = "RecoveryEvidenceRecorderTests.buildLabels"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let labels = PhysicalBuildLabelStore(defaults: defaults)
        labels.setLabel("b-1a2b", forInstruction: "abc123")
        func recorder(staged: StagedFixtureDeclaration?) -> RecoveryEvidenceRecorder {
            RecoveryEvidenceRecorder(
                root: root, instructionSHA256: "abc123", authoredModelID: UUID(), modelTitle: "Test Model",
                stepCount: 12, staged: staged, buildLabels: labels
            )
        }
        func declaration(physical: Bool) -> StagedFixtureDeclaration {
            StagedFixtureDeclaration(
                expectedCompletedCount: 3, lighting: .bright, occlusion: .none, physicalCase: physical, legalUseConfirmed: true
            )
        }
        func finalizedBuild(_ recorder: RecoveryEvidenceRecorder, truth: EvidenceGroundTruth) async throws -> String? {
            await recorder.recordCaptures([try makeCapture()])
            await recorder.finalize(estimate: nil, analysisError: nil, groundTruth: truth)
            let url = root
                .appendingPathComponent(RecoveryEvidenceRecorder.directoryName)
                .appendingPathComponent(recorder.sessionID.uuidString)
                .appendingPathComponent("session.json")
            return try EvidenceSchema.decoder().decode(EvidenceSessionFile.self, from: Data(contentsOf: url)).physicalBuildID
        }

        let stagedTruth = EvidenceGroundTruth(kind: .staged, expectedCompletedCount: 3)
        let staged = try await finalizedBuild(recorder(staged: declaration(physical: true)), truth: stagedTruth)
        XCTAssertEqual(staged, "b-1a2b")
        // A staged declaration without a physical build has nothing to label.
        let screen = try await finalizedBuild(recorder(staged: declaration(physical: false)), truth: stagedTruth)
        XCTAssertNil(screen)
        // A confirmed recovery takes the last label declared for the model;
        // an unlabeled session takes none.
        let confirmed = try await finalizedBuild(
            recorder(staged: nil), truth: EvidenceGroundTruth(kind: .confirmed, expectedCompletedCount: 2)
        )
        XCTAssertEqual(confirmed, "b-1a2b")
        let unlabeled = try await finalizedBuild(recorder(staged: nil), truth: .unlabeled)
        XCTAssertNil(unlabeled)
    }

    func testWindowFramesAreDeduplicatedAndStagedClosesWriteARow() async throws {
        let recorder = makeRecorder()
        let samples = (0..<4).map { index in windowSample(timestamp: TimeInterval(index)) }
        let staged = StagedVerificationDeclaration(
            scenario: .missing, lighting: .bright, occlusion: .none, physicalCase: true, legalUseConfirmed: true
        )
        // Two overlapping windows share frames 1–2; the verdict-change one
        // carries no row, the closing confirm does.
        await recorder.record(windowCapture(samples: Array(samples[0..<3]), trigger: .verdictChange, staged: staged))
        await recorder.record(windowCapture(samples: Array(samples[1..<4]), trigger: .confirm, staged: staged))

        let sessionDirectory = root
            .appendingPathComponent(RecoveryEvidenceRecorder.directoryName)
            .appendingPathComponent(recorder.sessionID.uuidString)
        let sidecars = try FileManager.default.contentsOfDirectory(
            at: sessionDirectory.appendingPathComponent("windows/frames"), includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        XCTAssertEqual(sidecars.count, 4, "each frame is written once however many windows hold it")
        let windows = try FileManager.default.contentsOfDirectory(
            at: sessionDirectory.appendingPathComponent("windows"), includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        XCTAssertEqual(windows.count, 2)

        let rows = try String(contentsOf: sessionDirectory.appendingPathComponent(RecoveryEvidenceRecorder.verificationRowsFilename), encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(rows[0].utf8)) as? [String: Any])
        XCTAssertEqual(row["kind"] as? String, "verification")
        XCTAssertEqual(row["provenance"] as? String, "device")
        XCTAssertEqual(row["expected_verdict"] as? String, "incomplete")
        XCTAssertEqual(row["produced_verdict"] as? String, "incomplete")
        XCTAssertEqual(row["window_trigger"] as? String, "confirm")
        XCTAssertNil(row["challenge_class"], "a release-eligible scenario must not carry challenge keys")
    }

    func testAWindowWithAShadowDiffWritesADiffRow() async throws {
        let recorder = makeRecorder()
        let samples = (0..<2).map { windowSample(timestamp: TimeInterval($0)) }
        let original = windowCapture(samples: samples, trigger: .confirm, staged: nil)
        let diff = BuildDiff(stepID: "main.ldr#3", observations: [
            PlacementObservation(placement: 4, state: .displaced(LatticeOffset(dx: 1)), evidence: PlacementEvidence(support: 12, absence: 3))
        ], framesUsed: 9)
        let capture = VerificationWindowCapture(
            windowID: original.windowID, stepID: original.stepID, stepIndex: original.stepIndex, trigger: .confirm,
            samples: original.samples, verification: original.verification, staged: nil,
            ingestMillisecondsSinceBegin: 70, createdAt: .now, shadowDiff: diff,
            shadowVerdict: original.verification.replacingVerdict(.misplaced(offsetStuds: SIMD2(1, 0)))
        )
        await recorder.record(capture)
        let url = root
            .appendingPathComponent(RecoveryEvidenceRecorder.directoryName)
            .appendingPathComponent(recorder.sessionID.uuidString)
            .appendingPathComponent(RecoveryEvidenceRecorder.diffRowsFilename)
        let record = try JSONDecoder().decode(BuildDiffRecord.self, from: try Data(contentsOf: url).split(separator: UInt8(ascii: "\n"))[0])
        XCTAssertEqual(record.windowID, capture.windowID)
        XCTAssertEqual(record.placements.first?.state, "displaced")
        XCTAssertEqual(record.placements.first?.offset, [1, 0, 0, 0])
        XCTAssertEqual(record.adapterVerdict, "misplaced")
        XCTAssertEqual(record.verifierVerdict, "incomplete")
    }

    func testAWindowCarriesTheColourTermReading() async throws {
        let recorder = makeRecorder()
        var capture = windowCapture(samples: (0..<2).map { windowSample(timestamp: TimeInterval($0)) }, trigger: .confirm, staged: nil)
        capture.colourTermMode = .shadow
        capture.colourAssessment = ColourAssessment(
            status: .disagrees(nearestCode: 14),
            groups: [.init(code: 1, status: .disagrees(nearestCode: 14), pixels: 120, frames: 4, observedOklab: nil,
                           authoredDistance: 0.31, nearestCode: 14, nearestDistance: 0.02, beneathCode: 4)],
            framesWithColour: 4, framesCalibrated: 4
        )
        await recorder.record(capture)
        let url = root
            .appendingPathComponent(RecoveryEvidenceRecorder.directoryName)
            .appendingPathComponent(recorder.sessionID.uuidString)
            .appendingPathComponent("windows/\(capture.windowID.uuidString).json")
        let record = try EvidenceSchema.decoder().decode(VerificationWindowRecord.self, from: Data(contentsOf: url))
        let colour = try XCTUnwrap(record.colourTerm)
        XCTAssertEqual(colour.mode, "shadow")
        XCTAssertEqual(colour.status, "disagrees")
        XCTAssertEqual(colour.groups.first?.nearestCode, 14)
        XCTAssertEqual(colour.groups.first?.beneathCode, 4)
        XCTAssertTrue(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("\"colour_term\""))

        // Without the term, the window says nothing about colour.
        let plain = windowCapture(samples: (0..<2).map { windowSample(timestamp: TimeInterval($0)) }, trigger: .confirm, staged: nil)
        await recorder.record(plain)
        let plainURL = url.deletingLastPathComponent().appendingPathComponent("\(plain.windowID.uuidString).json")
        XCTAssertNil(try EvidenceSchema.decoder().decode(VerificationWindowRecord.self, from: Data(contentsOf: plainURL)).colourTerm)
    }

    func testWordingAttemptsGoToTheirOwnFile() async throws {
        let recorder = makeRecorder()
        let record = RepairWordingRecordV1(
            sessionID: recorder.sessionID, stepID: "main.ldr#3", action: "move", partLabel: "red Brick 2 x 4",
            partCount: 1, direction: "your_left", studs: 1, turn: nil,
            template: "Move the red Brick 2 x 4 one stud to your left.",
            modelSentence: "Slide the red Brick 2 x 4 one stud to your left.", outcome: "accepted",
            shown: "Slide the red Brick 2 x 4 one stud to your left.", latencyMilliseconds: 900,
            osBuild: "24A430", deviceModel: "iPhone18,1", createdAt: Date(timeIntervalSince1970: 0)
        )
        await recorder.recordWording(record)
        await recorder.recordWording(record)
        let url = root
            .appendingPathComponent(RecoveryEvidenceRecorder.directoryName)
            .appendingPathComponent(recorder.sessionID.uuidString)
            .appendingPathComponent(RepairWordingRecordV1.filename)
        let lines = try Data(contentsOf: url).split(separator: UInt8(ascii: "\n"))
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(try EvidenceSchema.decoder().decode(RepairWordingRecordV1.self, from: Data(lines[0])), record)
        XCTAssertTrue(String(decoding: lines[0], as: UTF8.self).contains(#""model_sentence""#))
    }

    private func windowSample(timestamp: TimeInterval, runnerUp: LatticeAlternative? = nil) -> VerificationWindowSample {
        VerificationWindowSample(
            frameID: UUID(),
            frame: RegistrationFrameInput(
                depth: [Float32](repeating: 0.4, count: 12), confidence: [UInt8](repeating: 2, count: 12),
                rawDepth: nil, rawConfidence: nil, width: 4, height: 3,
                depthIntrinsics: matrix_identity_float3x3, worldFromCamera: matrix_identity_float4x4,
                timestamp: timestamp, colour: [UInt8](repeating: 90, count: 36), colourEncoding: "rgb8_bt709_full",
                occluderMask: [UInt8](repeating: 0, count: 12)
            ),
            registration: ModelRegistration(
                alignmentID: UUID(), worldFromModel: matrix_identity_float4x4, state: .locked,
                quality: RegistrationQuality(
                    rmsResidual: 0.002, inlierFraction: 0.8, latticeMargin: 2, latticeRunnerUp: runnerUp
                ),
                fittedStepIndex: 2, timestamp: timestamp
            ),
            result: verificationResult(.incomplete, timestamp: timestamp),
            ingestMilliseconds: 7
        )
    }

    private func verificationResult(_ verdict: StepVerdict, timestamp: TimeInterval) -> StepVerification {
        StepVerification(
            stepID: "main.ldr#3", verdict: verdict, detectability: .strong, deltaPixels: 140, framesUsed: 12,
            completeFraction: 0.1, incompleteFraction: 0.8, registrationQuality: .none, timestamp: timestamp
        )
    }

    private func windowCapture(
        samples: [VerificationWindowSample], trigger: VerificationWindowRecord.Trigger,
        staged: StagedVerificationDeclaration?
    ) -> VerificationWindowCapture {
        VerificationWindowCapture(
            windowID: UUID(), stepID: "main.ldr#3", stepIndex: 2, trigger: trigger, samples: samples,
            verification: verificationResult(.incomplete, timestamp: samples.last?.frame.timestamp ?? 0),
            staged: staged, ingestMillisecondsSinceBegin: 70, createdAt: .now
        )
    }

    private func sessionFile(_ recorder: RecoveryEvidenceRecorder) throws -> EvidenceSessionFile {
        try EvidenceSchema.decoder().decode(
            EvidenceSessionFile.self,
            from: Data(contentsOf: root
                .appendingPathComponent(RecoveryEvidenceRecorder.directoryName)
                .appendingPathComponent(recorder.sessionID.uuidString)
                .appendingPathComponent("session.json"))
        )
    }

    // Fails on the old code by not compiling, and by behaviour before that:
    // a failed write left no trace outside the device log.
    func testAFailedWriteIsCountedInTheSessionFile() async throws {
        let recorder = makeRecorder()
        var missing = try makeCapture()
        try FileManager.default.removeItem(at: root.appendingPathComponent(missing.imageRelativePath))
        await recorder.recordCaptures([missing])
        var health = try XCTUnwrap(try sessionFile(recorder).recorderHealth)
        XCTAssertEqual(health.writeFailures, 1)
        XCTAssertEqual(health.failedOperations, ["record captures": 1])

        // A later successful write keeps the count.
        missing = try makeCapture()
        await recorder.recordCaptures([missing])
        health = try XCTUnwrap(try sessionFile(recorder).recorderHealth)
        XCTAssertEqual(health.writeFailures, 1)
        XCTAssertEqual(try sessionFile(recorder).captures.map(\.captureID), [missing.id])
    }

    func testACleanSessionRecordsNoHealth() async throws {
        let recorder = makeRecorder()
        await recorder.recordCaptures([try makeCapture()])
        XCTAssertNil(try sessionFile(recorder).recorderHealth)
    }

    func testWindowsPastTheCapAreCountedNotWritten() async throws {
        let recorder = makeRecorder()
        for _ in 0..<(RecoveryEvidenceRecorder.maxWindowsPerSession + 2) {
            await recorder.record(windowCapture(samples: [], trigger: .confirm, staged: nil))
        }
        let windows = root
            .appendingPathComponent(RecoveryEvidenceRecorder.directoryName)
            .appendingPathComponent(recorder.sessionID.uuidString)
            .appendingPathComponent("windows")
        let written = try FileManager.default.contentsOfDirectory(atPath: windows.path).filter { $0.hasSuffix(".json") }
        XCTAssertEqual(written.count, RecoveryEvidenceRecorder.maxWindowsPerSession)
        let health = try XCTUnwrap(try sessionFile(recorder).recorderHealth)
        XCTAssertEqual(health.windowsSkippedAtCap, 2)
        XCTAssertEqual(health.windowsSkippedLowSpace, 0)
        XCTAssertEqual(health.writeFailures, 0)
    }

    func testWindowSkipReasons() {
        let cap = RecoveryEvidenceRecorder.maxWindowsPerSession
        let plenty = RecoveryEvidenceRecorder.minimumFreeBytesForWindows
        XCTAssertNil(RecoveryEvidenceRecorder.windowSkip(windowsWritten: 0, freeBytes: plenty))
        XCTAssertNil(RecoveryEvidenceRecorder.windowSkip(windowsWritten: cap - 1, freeBytes: nil))
        XCTAssertEqual(RecoveryEvidenceRecorder.windowSkip(windowsWritten: 0, freeBytes: plenty - 1), .lowSpace)
        // Both apply: counted once, under the cap.
        XCTAssertEqual(RecoveryEvidenceRecorder.windowSkip(windowsWritten: cap, freeBytes: 0), .atCap)
    }

    func testPurgeRemovesOldestSessionsBeyondCap() throws {
        let store = root.appendingPathComponent(RecoveryEvidenceRecorder.directoryName, isDirectory: true)
        let sessionTotal = RecoveryEvidenceRecorder.maxSessions + 5
        for index in 0..<sessionTotal {
            let directory = store.appendingPathComponent("session-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: directory.appendingPathComponent("session.json"))
            // Distinct creation dates so "oldest" is well defined.
            try FileManager.default.setAttributes(
                [.creationDate: Date(timeIntervalSince1970: TimeInterval(index))],
                ofItemAtPath: directory.path
            )
        }
        try RecoveryEvidenceRecorder.purgeIfNeeded(root: root)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: store.path).sorted()
        XCTAssertEqual(remaining.count, RecoveryEvidenceRecorder.maxSessions - 1)
        XCTAssertFalse(remaining.contains("session-0"))
        XCTAssertTrue(remaining.contains("session-\(sessionTotal - 1)"))
    }

    // MARK: - Fixtures

    private func makeFit(
        sessionID: UUID,
        candidateIndex: Int,
        conclusive: Bool
    ) -> GeometricFitRecord {
        GeometricFitRecord(
            fitVersion: EvidenceSchema.fitVersion,
            fitID: UUID(),
            sessionID: sessionID,
            passIndex: 0,
            candidateIndex: candidateIndex,
            stepID: "main.ldr#\(candidateIndex + 1)",
            score: 0.6,
            inlierFraction: 0.5,
            visibleFraction: 0.4,
            unexplainedFraction: 0.1,
            phantomFraction: 0.05,
            rmsResidual: 0.004,
            latticeMargin: 1.4,
            worldFromModel: Array(repeating: 0, count: 16),
            disqualification: .none,
            conclusive: conclusive,
            createdAt: .now
        )
    }

    private func makeRecorder(staged: StagedFixtureDeclaration? = nil) -> RecoveryEvidenceRecorder {
        RecoveryEvidenceRecorder(
            root: root,
            instructionSHA256: "abc123",
            authoredModelID: UUID(),
            modelTitle: "Test Model",
            stepCount: 12,
            staged: staged
        )
    }

    private func makeCapture(angle: CaptureAngle = .center) throws -> RecoveryCapture {
        let captures = root.appendingPathComponent("RecoveryCaptures", isDirectory: true)
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        let id = UUID()
        let filename = "\(id.uuidString).jpg"
        try Data("capture".utf8).write(to: captures.appendingPathComponent(filename))
        return RecoveryCapture(
            id: id,
            imageRelativePath: "RecoveryCaptures/\(filename)",
            cameraTransform: Array(repeating: 0, count: 16),
            cameraIntrinsics: Array(repeating: 0, count: 9),
            cameraImageResolution: [1920, 1440],
            alignmentID: UUID(),
            angle: angle,
            capturedAt: .now
        )
    }

    private func makeTrace() -> MLXGenerationTrace {
        MLXGenerationTrace(
            rawOutput: #"{"status":"matched","ranking":["B"]}"#,
            decodeErrorDescription: nil,
            generatedTokens: 14,
            termination: .accepted,
            latencyMilliseconds: 1200,
            maxTokens: 192,
            schemaJSON: "{}"
        )
    }

    private func loadTraceRows(sessionDirectory: URL) throws -> [EvidenceTraceRow] {
        let data = try Data(contentsOf: sessionDirectory.appendingPathComponent("traces.ndjson"))
        let decoder = EvidenceSchema.decoder()
        return try data.split(separator: UInt8(ascii: "\n")).map {
            try decoder.decode(EvidenceTraceRow.self, from: Data($0))
        }
    }
}
