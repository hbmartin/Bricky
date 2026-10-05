import CoreGraphics
import XCTest
@testable import RecoveryEvidenceKit

final class EvidenceKitTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kit-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Board layout

    func testComposedBoardIsExactlyBoardSidePixels() throws {
        let board = try RecoveryBoardLayoutV1.composeBoard(
            physical: try solidImage(width: 1440, height: 1920),
            candidates: (0..<8).map { offset in
                RecoveryBoardLayoutV1.Candidate(
                    slot: String(UnicodeScalar(UInt8(65 + offset))),
                    image: try! solidImage(width: 512, height: 384),
                    stepNumber: offset + 1
                )
            }
        )
        XCTAssertEqual(board.width, RecoveryBoardLayoutV1.boardSide)
        XCTAssertEqual(board.height, RecoveryBoardLayoutV1.boardSide)
    }

    func testComposeRejectsEmptyAndOversizedCandidateSets() throws {
        let physical = try solidImage(width: 64, height: 64)
        XCTAssertThrowsError(try RecoveryBoardLayoutV1.composeBoard(physical: physical, candidates: []))
        let nine = (0..<9).map { offset in
            RecoveryBoardLayoutV1.Candidate(slot: "\(offset)", image: physical, stepNumber: offset)
        }
        XCTAssertThrowsError(try RecoveryBoardLayoutV1.composeBoard(physical: physical, candidates: nine))
    }

    func testJPEGRoundTrip() throws {
        let url = root.appendingPathComponent("board.jpg")
        try RecoveryBoardLayoutV1.writeJPEG(try solidImage(width: 100, height: 80), to: url)
        let loaded = try RecoveryBoardLayoutV1.loadImage(at: url)
        XCTAssertEqual(loaded.width, 100)
        XCTAssertEqual(loaded.height, 80)
    }

    // MARK: - Bundle reader

    func testReaderValidatesGoodBundleAndFlagsMissingFiles() throws {
        let bundleDirectory = try makeBundle()
        let reader = try EvidenceBundleReader(bundleDirectory: bundleDirectory)
        XCTAssertEqual(reader.validate(), [])
        let sessions = try reader.loadSessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].traceRows.count, 1)
        XCTAssertEqual(sessions[0].file.groundTruth.kind, .staged)

        // Deleting a referenced board must surface as an issue.
        let board = sessions[0].directory.appendingPathComponent(sessions[0].traceRows[0].boardRelativePath)
        try FileManager.default.removeItem(at: board)
        XCTAssertFalse(reader.validate().isEmpty)
    }

    func testReaderRejectsUnsupportedBundleVersion() throws {
        let bundleDirectory = try makeBundle(bundleVersion: 99)
        let reader = try EvidenceBundleReader(bundleDirectory: bundleDirectory)
        XCTAssertTrue(reader.validate().contains { $0.contains("bundle_version") })
    }

    // MARK: - Geometric fit records

    func testBundleWithoutFitsIsStillValid() throws {
        // A VLM-only recovery writes no fits.ndjson; that is not a defect.
        let bundleDirectory = try makeBundle()
        let reader = try EvidenceBundleReader(bundleDirectory: bundleDirectory)
        XCTAssertEqual(reader.validate(), [])
        XCTAssertTrue(try reader.loadSessions()[0].fitRecords.isEmpty)
    }

    func testFitRecordsRoundTripThroughABundle() throws {
        let sessionID = UUID()
        let bundleDirectory = try makeBundle(sessionID: sessionID, fits: [
            Self.fitRecord(sessionID: sessionID, disqualification: .verticalDeviation, conclusive: false),
            Self.fitRecord(sessionID: sessionID),
        ])
        let reader = try EvidenceBundleReader(bundleDirectory: bundleDirectory)
        XCTAssertEqual(reader.validate(), [])
        let fits = try reader.loadSessions()[0].fitRecords
        XCTAssertEqual(fits.count, 2)
        // The reason a candidate was ruled out survives the round trip; the
        // clamped score alone could never carry it.
        XCTAssertEqual(fits[0].disqualification, .verticalDeviation)
        XCTAssertFalse(fits[0].conclusive)
        XCTAssertEqual(fits[1].disqualification, .none)
        XCTAssertTrue(fits[1].conclusive)
        XCTAssertEqual(fits[1].phantomFraction, 0.02, accuracy: 1e-6)
    }

    func testReaderRejectsUnsupportedFitVersion() throws {
        let sessionID = UUID()
        let bundleDirectory = try makeBundle(sessionID: sessionID, fits: [
            Self.fitRecord(sessionID: sessionID, fitVersion: 99),
        ])
        let reader = try EvidenceBundleReader(bundleDirectory: bundleDirectory)
        XCTAssertTrue(reader.validate().contains { $0.contains("fit_version") })
    }

    func testReaderRejectsAFitFromAForeignSession() throws {
        // A fit naming another session would replay against the wrong
        // captures; ownership must be validated, not assumed.
        let bundleDirectory = try makeBundle(fits: [Self.fitRecord(sessionID: UUID())])
        let reader = try EvidenceBundleReader(bundleDirectory: bundleDirectory)
        XCTAssertTrue(reader.validate().contains { $0.contains("belongs to session") })
    }

    func testReaderRejectsAPoseThatCannotBeReshaped() throws {
        let sessionID = UUID()
        let bundleDirectory = try makeBundle(sessionID: sessionID, fits: [
            Self.fitRecord(sessionID: sessionID, pose: Array(repeating: 0, count: 12)),
        ])
        let reader = try EvidenceBundleReader(bundleDirectory: bundleDirectory)
        XCTAssertTrue(reader.validate().contains { $0.contains("expected 16") })
    }

    func testFitRecordKeysAreSnakeCase() throws {
        let bundleDirectory = try makeBundle(fits: [Self.fitRecord(sessionID: UUID())])
        let sessions = try EvidenceBundleReader(bundleDirectory: bundleDirectory).loadSessions()
        let raw = try String(
            contentsOf: sessions[0].directory.appendingPathComponent("fits.ndjson"),
            encoding: .utf8
        )
        for key in [
            "fit_version", "fit_id", "session_id", "pass_index", "candidate_index",
            "step_id", "inlier_fraction", "visible_fraction", "unexplained_fraction",
            "phantom_fraction", "rms_residual", "lattice_margin", "world_from_model",
            "created_at",
        ] {
            XCTAssertTrue(raw.contains("\"\(key)\""), "missing \(key)")
        }
    }

    // MARK: - Retained depth frames

    func testBundleWithoutDepthIsStillValid() throws {
        let reader = try EvidenceBundleReader(bundleDirectory: try makeBundle())
        XCTAssertEqual(reader.validate(), [])
        XCTAssertTrue(try reader.loadSessions()[0].depthFrames.isEmpty)
    }

    func testDepthFrameRoundTripsAndPlanesReshape() throws {
        let bundleDirectory = try makeBundle()
        let reader = try EvidenceBundleReader(bundleDirectory: bundleDirectory)
        let session = try reader.loadSessions()[0]
        let sessionDirectory = session.directory
        // The frame must reference a capture this session actually owns.
        let captureID = session.file.captures[0].captureID
        try Self.writeDepthFrame(into: sessionDirectory, captureID: captureID, width: 4, height: 3)

        XCTAssertEqual(reader.validate(), [])
        let frame = try XCTUnwrap(try reader.loadSessions()[0].depthFrames.first)
        XCTAssertEqual(frame.captureID, captureID)
        XCTAssertEqual(frame.width, 4)
        XCTAssertEqual(frame.height, 3)
        XCTAssertEqual(frame.expectedBytes(elementSize: MemoryLayout<Float32>.size), 48)

        // The plane must reshape to exactly width x height, which is the only
        // thing that makes the blob usable without a decoder.
        let data = try Data(contentsOf: sessionDirectory.appendingPathComponent(frame.depthRelativePath))
        XCTAssertEqual(data.count, 48)
        let values = data.withUnsafeBytes { Array($0.bindMemory(to: Float32.self)) }
        XCTAssertEqual(values.count, 12)
        XCTAssertEqual(values.first, 0.5)
    }

    func testReaderRejectsATruncatedDepthPlane() throws {
        let bundleDirectory = try makeBundle()
        let reader = try EvidenceBundleReader(bundleDirectory: bundleDirectory)
        let session = try reader.loadSessions()[0]
        // Declares 4x3 but writes 8 floats: reshaping this would silently
        // produce wrong geometry rather than fail.
        try Self.writeDepthFrame(
            into: session.directory, captureID: session.file.captures[0].captureID,
            width: 4, height: 3, depthElements: 8
        )
        XCTAssertTrue(reader.validate().contains { $0.contains("expected 48") })
    }

    func testReaderRejectsUnsupportedDepthVersion() throws {
        let bundleDirectory = try makeBundle()
        let reader = try EvidenceBundleReader(bundleDirectory: bundleDirectory)
        let session = try reader.loadSessions()[0]
        try Self.writeDepthFrame(
            into: session.directory, captureID: session.file.captures[0].captureID, depthVersion: 99
        )
        XCTAssertTrue(reader.validate().contains { $0.contains("depth_version") })
    }

    func testReaderRejectsADepthFrameFromAForeignCapture() throws {
        // A depth frame is only usable through the capture it observed; one
        // referencing a capture this session does not own is orphaned data.
        let bundleDirectory = try makeBundle()
        let reader = try EvidenceBundleReader(bundleDirectory: bundleDirectory)
        let sessionDirectory = try reader.loadSessions()[0].directory
        try Self.writeDepthFrame(into: sessionDirectory, captureID: UUID())
        XCTAssertTrue(reader.validate().contains { $0.contains("references no capture") })
    }

    func testReaderRejectsNonPositiveDepthDimensions() throws {
        for (width, height) in [(0, 3), (4, -3)] {
            let bundleDirectory = try makeBundle()
            let reader = try EvidenceBundleReader(bundleDirectory: bundleDirectory)
            let session = try reader.loadSessions()[0]
            // A 0 x N plane would pass a naive byte-size check with an empty
            // file; dimensions must be rejected before sizes are compared.
            try Self.writeDepthFrame(
                into: session.directory, captureID: session.file.captures[0].captureID,
                width: width, height: height, depthElements: 0
            )
            XCTAssertTrue(
                reader.validate().contains { $0.contains("non-positive dimensions") },
                "\(width)x\(height) must be rejected"
            )
            try FileManager.default.removeItem(at: bundleDirectory)
        }
    }

    func testReaderRejectsOverflowingDepthDimensions() throws {
        let bundleDirectory = try makeBundle()
        let reader = try EvidenceBundleReader(bundleDirectory: bundleDirectory)
        let session = try reader.loadSessions()[0]
        // width * height overflows Int; the reader must report, not trap.
        try Self.writeDepthFrame(
            into: session.directory, captureID: session.file.captures[0].captureID,
            width: Int.max, height: 2, depthElements: 0
        )
        XCTAssertTrue(reader.validate().contains { $0.contains("overflow") })
    }

    func testReaderRejectsMalformedIntrinsicsAndPose() throws {
        let bundleDirectory = try makeBundle()
        let reader = try EvidenceBundleReader(bundleDirectory: bundleDirectory)
        let session = try reader.loadSessions()[0]
        // Intrinsics that cannot reshape to 3x3 and a pose that cannot
        // reshape to 4x4 make the frame unusable for any geometric replay.
        try Self.writeDepthFrame(
            into: session.directory, captureID: session.file.captures[0].captureID,
            intrinsicsCount: 4, poseCount: 12
        )
        let issues = reader.validate()
        XCTAssertTrue(issues.contains { $0.contains("expected 9") })
        XCTAssertTrue(issues.contains { $0.contains("expected 16") })
    }

    func testExpectedBytesRejectsDegenerateDimensions() throws {
        func record(width: Int, height: Int) -> EvidenceDepthFrameRecord {
            EvidenceDepthFrameRecord(
                depthVersion: EvidenceSchema.depthVersion, captureID: UUID(),
                width: width, height: height,
                depthIntrinsics: Array(repeating: 1, count: 9),
                worldFromCamera: Array(repeating: 0, count: 16),
                timestamp: 0, depthRelativePath: "d", confidenceRelativePath: "c",
                rawDepthRelativePath: nil, rawConfidenceRelativePath: nil
            )
        }
        XCTAssertEqual(record(width: 4, height: 3).expectedBytes(elementSize: 4), 48)
        XCTAssertNil(record(width: 0, height: 3).expectedBytes(elementSize: 4))
        XCTAssertNil(record(width: 4, height: -3).expectedBytes(elementSize: 4))
        XCTAssertNil(record(width: Int.max, height: 2).expectedBytes(elementSize: 4))
        XCTAssertNil(record(width: Int.max / 2, height: 1).expectedBytes(elementSize: 4))
    }

    func testSchemaKeysAreSnakeCase() throws {
        let bundleDirectory = try makeBundle()
        let raw = try String(
            contentsOf: bundleDirectory.appendingPathComponent("evidence_bundle.json"),
            encoding: .utf8
        )
        for key in ["bundle_version", "model_revision", "session_ids", "device_model"] {
            XCTAssertTrue(raw.contains("\"\(key)\""), "missing \(key)")
        }
    }

    // MARK: - Capture elevation

    /// A column-major camera-to-world transform whose optical axis (−Z)
    /// points `degrees` below the horizon.
    private func pitchedDown(_ degrees: Double) -> [Float] {
        let radians = degrees * .pi / 180
        let (sine, cosine) = (Float(sin(radians)), Float(cos(radians)))
        return [
            1, 0, 0, 0,
            0, cosine, -sine, 0,
            0, sine, cosine, 0,
            0, 0, 0, 1
        ]
    }

    private func capture(angle: String, transform: [Float]) -> EvidenceCaptureRecord {
        EvidenceCaptureRecord(
            captureID: UUID(), imageRelativePath: "captures/x.jpg", cameraTransform: transform,
            cameraIntrinsics: Array(repeating: 0, count: 9), cameraImageResolution: [1920, 1440],
            alignmentID: UUID(), angle: angle, capturedAt: .now
        )
    }

    func testElevationIsTheOpticalAxisAngleBelowTheHorizon() throws {
        for degrees in [0.0, 30.0, 45.0, 90.0] {
            let elevation = try XCTUnwrap(capture(angle: "center", transform: pitchedDown(degrees)).elevationDegrees)
            XCTAssertEqual(elevation, degrees, accuracy: 0.01)
        }
        // Looking up reads negative, not folded back into the downward range.
        let upward = try XCTUnwrap(capture(angle: "center", transform: pitchedDown(-20)).elevationDegrees)
        XCTAssertEqual(upward, -20, accuracy: 0.01)
    }

    func testMalformedTransformHasNoElevation() {
        XCTAssertNil(capture(angle: "center", transform: [1, 0, 0]).elevationDegrees)
        var poisoned = pitchedDown(45)
        poisoned[9] = .nan
        XCTAssertNil(capture(angle: "center", transform: poisoned).elevationDegrees)
    }

    func testBenchmarkElevationPrefersTheCenterCapture() throws {
        let captures = [
            capture(angle: "left", transform: pitchedDown(20)),
            capture(angle: "center", transform: pitchedDown(55)),
            capture(angle: "right", transform: pitchedDown(20))
        ]
        XCTAssertEqual(try XCTUnwrap(captures.benchmarkElevationDegrees), 55, accuracy: 0.01)
        XCTAssertNil([EvidenceCaptureRecord]().benchmarkElevationDegrees)
    }

    func testBenchmarkElevationKeyIsSnakeCase() throws {
        let row = RecoveryBenchmarkV1(
            schemaVersion: 1, fixtureID: "f", instructionSHA256: "0", pyldraw3Version: "1.5.0",
            partPackVersion: "2026-07", expectedStepID: "m#1", candidateSlots: [:],
            boardRelativePaths: [], cameraMetadata: [], expectedStepIndex: 1, rankedStepIDs: [],
            certainty: .insufficient, estimatorMethod: .vlm, modelRevision: nil, deviceModel: "iPhone18,1",
            operatingSystem: "iOS", latencyMilliseconds: 0, memoryPeakBytes: 0, topStepIndex: nil,
            physicalCase: nil, authoredModelID: nil, legalUseConfirmed: nil, lightingCondition: nil,
            captureAngle: nil, occlusionCondition: nil, captureElevationDegrees: 42.5
        )
        let raw = String(decoding: try EvidenceSchema.encoder().encode(row), as: UTF8.self)
        XCTAssertTrue(raw.contains("\"capture_elevation_degrees\":42.5"), raw)
    }

    // MARK: - Telemetry

    func testMemorySnapshotReadsTheKernelLedger() throws {
        let snapshot = try XCTUnwrap(ProcessMemorySnapshot.current())
        XCTAssertGreaterThan(snapshot.footprintBytes, 0)
        let peak = try XCTUnwrap(snapshot.lifetimePeakBytes)
        XCTAssertGreaterThanOrEqual(peak, snapshot.footprintBytes)
    }

    #if os(macOS)
    func testMacIdentifierIsTheModelNotTheCPU() {
        // uname reports "arm64" on a Mac; replay rows need "Mac14,12".
        XCTAssertNotEqual(DeviceIdentity.modelIdentifier, "arm64")
        XCTAssertTrue(DeviceIdentity.modelIdentifier.contains(","), DeviceIdentity.modelIdentifier)
        XCTAssertNotNil(DeviceIdentity.osBuild)
    }
    #endif

    func testLatencyBuckets() {
        XCTAssertEqual(LatencyBucket.classify(callsSinceLoad: 0, secondsSinceARStart: 60), .cold)
        XCTAssertEqual(LatencyBucket.classify(callsSinceLoad: 4, secondsSinceARStart: 60), .warm)
        XCTAssertEqual(LatencyBucket.classify(callsSinceLoad: 4, secondsSinceARStart: 1_800), .sustained)
        XCTAssertEqual(LatencyBucket.classify(callsSinceLoad: nil, secondsSinceARStart: nil), .warm)
    }

    func testVariantIDNamesOnlyTheAxesThatDiffer() {
        XCTAssertEqual(RecoveryInferenceVariant.baseline.id, "baseline")
        XCTAssertEqual(RecoveryInferenceVariant(decode: .feedAll).id, "decode=feed_all")
        XCTAssertEqual(RecoveryInferenceVariant(decode: .feedAll, vote: .bordaLegacy).id, "decode=feed_all,vote=borda_legacy")
        XCTAssertEqual(RecoveryInferenceVariant(armID: "B").id, "baseline", "the arm label is not an axis")
    }

    func testTelemetryFieldsAreOptionalAndSnakeCase() throws {
        // A trace row written before any telemetry existed still decodes.
        let legacy = #"{"trace_version":1,"trace_id":"00000000-0000-0000-0000-000000000001","session_id":"00000000-0000-0000-0000-000000000002","pass":"finalist","pass_index":0,"board_relative_path":"b.jpg","tile_relative_paths":{},"candidate_step_indices":{},"candidate_step_ids":{},"prompt":"p","schema_json":"{}","max_tokens":192,"raw_output":"{}","termination":"accepted","latency_ms":1,"model_revision":"r","created_at":"2026-09-25T00:00:00Z"}"#
        let row = try EvidenceSchema.decoder().decode(EvidenceTraceRow.self, from: Data(legacy.utf8))
        XCTAssertNil(row.inference)
        XCTAssertNil(row.variant)

        let conditions = DeviceConditions(thermalState: "nominal", lowPowerMode: false, secondsSinceARStart: 12)
        let inference = InferenceTelemetry(thermalBefore: "fair", callsSinceLoad: 0, loadMilliseconds: 900)
        let raw = String(decoding: try EvidenceSchema.encoder().encode(conditions), as: UTF8.self)
            + String(decoding: try EvidenceSchema.encoder().encode(inference), as: UTF8.self)
            + String(decoding: try EvidenceSchema.encoder().encode(AdmissionSnapshot(floorBytes: 1, warmUpPeakBytes: 2)), as: UTF8.self)
        for key in ["thermal_state", "low_power_mode", "seconds_since_ar_start", "thermal_before",
                    "calls_since_load", "load_ms", "floor_bytes", "warm_up_peak_bytes"] {
            XCTAssertTrue(raw.contains("\"\(key)\""), key)
        }
    }

    func testModelPeakCostIsMaskedByAnEarlierPeak() throws {
        // A fresh process: loading raised the peak, so the cost is the
        // warm-up peak less the footprint before load.
        let fresh = AdmissionSnapshot(
            floorBytes: 1, footprintBeforeLoadBytes: 1_000, warmUpPeakBytes: 5_000,
            lifetimePeakBeforeLoadBytes: 1_200
        )
        XCTAssertEqual(fresh.modelPeakCostBytes, 4_000)
        XCTAssertFalse(fresh.isPeakMasked)

        // A reload after an idle unload: the earlier load already set the
        // lifetime peak, so the after-warm-up peak is not this load's.
        let reload = AdmissionSnapshot(
            floorBytes: 1, footprintBeforeLoadBytes: 1_000, warmUpPeakBytes: 5_000,
            lifetimePeakBeforeLoadBytes: 5_000
        )
        XCTAssertNil(reload.modelPeakCostBytes)
        XCTAssertTrue(reload.isPeakMasked)

        // Rows written before the field existed decode and claim nothing.
        let legacy = try EvidenceSchema.decoder().decode(
            AdmissionSnapshot.self,
            from: Data(#"{"floor_bytes":1,"footprint_before_load_bytes":1000,"warm_up_peak_bytes":5000}"#.utf8)
        )
        XCTAssertNil(legacy.lifetimePeakBeforeLoadBytes)
        XCTAssertNil(legacy.modelPeakCostBytes)
        XCTAssertFalse(legacy.isPeakMasked)
        let raw = String(decoding: try EvidenceSchema.encoder().encode(reload), as: UTF8.self)
        XCTAssertTrue(raw.contains("\"lifetime_peak_before_load_bytes\""))
    }

    // MARK: - Fixtures

    private func solidImage(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    /// A conclusive geometric fit, the shape `GeometricRecoveryEstimator`
    /// emits. `overrides` lets a test corrupt exactly one field.
    static func fitRecord(
        sessionID: UUID,
        fitVersion: Int = EvidenceSchema.fitVersion,
        pose: [Float] = Array(repeating: 0, count: 16),
        disqualification: FitDisqualification = .none,
        conclusive: Bool = true
    ) -> GeometricFitRecord {
        GeometricFitRecord(
            fitVersion: fitVersion,
            fitID: UUID(),
            sessionID: sessionID,
            passIndex: 0,
            candidateIndex: 1,
            stepID: "main.ldr#2",
            score: 0.82,
            inlierFraction: 0.71,
            visibleFraction: 0.64,
            unexplainedFraction: 0.04,
            phantomFraction: 0.02,
            rmsResidual: 0.0031,
            latticeMargin: 1.8,
            worldFromModel: pose,
            disqualification: disqualification,
            conclusive: conclusive,
            createdAt: .now
        )
    }

    /// Writes a depth sidecar and its planes into a session directory.
    /// `depthElements` overrides the plane size so a test can truncate it;
    /// `intrinsicsCount`/`poseCount` let a test malform the metadata.
    @discardableResult
    static func writeDepthFrame(
        into sessionDirectory: URL,
        captureID: UUID,
        width: Int = 4,
        height: Int = 3,
        depthVersion: Int = EvidenceSchema.depthVersion,
        depthElements: Int? = nil,
        intrinsicsCount: Int = 9,
        poseCount: Int = 16
    ) throws -> EvidenceDepthFrameRecord {
        let stem = "depth/\(captureID.uuidString)"
        try FileManager.default.createDirectory(
            at: sessionDirectory.appendingPathComponent("depth", isDirectory: true),
            withIntermediateDirectories: true
        )
        // Degenerate declared dimensions (tests for the validator) still need
        // writable plane files; clamp without trapping on overflow.
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        let planeElements = overflow ? 0 : max(0, pixels)
        let depth = [Float32](repeating: 0.5, count: depthElements ?? planeElements)
        try depth.withUnsafeBufferPointer {
            try Data(buffer: $0).write(to: sessionDirectory.appendingPathComponent("\(stem).depth"))
        }
        let confidence = [UInt8](repeating: 2, count: planeElements)
        try confidence.withUnsafeBufferPointer {
            try Data(buffer: $0).write(to: sessionDirectory.appendingPathComponent("\(stem).confidence"))
        }
        let record = EvidenceDepthFrameRecord(
            depthVersion: depthVersion,
            captureID: captureID,
            width: width,
            height: height,
            depthIntrinsics: Array(repeating: 1, count: intrinsicsCount),
            worldFromCamera: Array(repeating: 0, count: poseCount),
            timestamp: 12.5,
            depthRelativePath: "\(stem).depth",
            confidenceRelativePath: "\(stem).confidence",
            rawDepthRelativePath: nil,
            rawConfidenceRelativePath: nil
        )
        try EvidenceSchema.encoder(prettyPrinted: true).encode(record)
            .write(to: sessionDirectory.appendingPathComponent("\(stem).json"))
        return record
    }

    /// Builds a minimal on-disk bundle with one staged session and one trace.
    /// Pass `sessionID` when fixture records must be owned by the session.
    private func makeBundle(
        bundleVersion: Int = EvidenceSchema.bundleVersion,
        sessionID: UUID = UUID(),
        fits: [GeometricFitRecord]? = nil
    ) throws -> URL {
        let bundleDirectory = root.appendingPathComponent("bundle", isDirectory: true)
        let traceID = UUID()
        let captureID = UUID()
        let sessionDirectory = bundleDirectory
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
        for sub in ["captures", "boards", "tiles/\(traceID.uuidString)"] {
            try FileManager.default.createDirectory(
                at: sessionDirectory.appendingPathComponent(sub, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        let jpeg = try solidImage(width: 32, height: 32)
        try RecoveryBoardLayoutV1.writeJPEG(jpeg, to: sessionDirectory.appendingPathComponent("captures/\(captureID.uuidString).jpg"))
        try RecoveryBoardLayoutV1.writeJPEG(jpeg, to: sessionDirectory.appendingPathComponent("boards/\(traceID.uuidString).jpg"))
        try RecoveryBoardLayoutV1.writeJPEG(jpeg, to: sessionDirectory.appendingPathComponent("tiles/\(traceID.uuidString)/A.jpg"))

        let encoder = EvidenceSchema.encoder(prettyPrinted: true)
        let manifest = EvidenceBundleManifest(
            bundleVersion: bundleVersion,
            createdAt: .now,
            appVersion: "2.0.0",
            deviceModel: "iPhone17,1",
            operatingSystem: "iOS 17.0",
            modelID: "mlx-community/Qwen3-VL-4B-Instruct-4bit",
            modelRevision: "2fd8dacbdb8f1e54b8c005f081ec5bf79c56376b",
            sessionIDs: [sessionID]
        )
        try encoder.encode(manifest)
            .write(to: bundleDirectory.appendingPathComponent("evidence_bundle.json"))

        let session = EvidenceSessionFile(
            sessionVersion: EvidenceSchema.sessionVersion,
            sessionID: sessionID,
            createdAt: .now,
            instructionSHA256: String(repeating: "0", count: 64),
            authoredModelID: UUID(),
            modelTitle: "Fixture Model",
            stepCount: 4,
            modelRevision: manifest.modelRevision,
            deviceModel: manifest.deviceModel,
            operatingSystem: manifest.operatingSystem,
            appVersion: manifest.appVersion,
            captures: [EvidenceCaptureRecord(
                captureID: captureID,
                imageRelativePath: "captures/\(captureID.uuidString).jpg",
                cameraTransform: Array(repeating: 0, count: 16),
                cameraIntrinsics: Array(repeating: 0, count: 9),
                cameraImageResolution: [1920, 1440],
                alignmentID: UUID(),
                angle: "center",
                capturedAt: .now
            )],
            staged: StagedFixtureDeclaration(
                expectedCompletedCount: 2,
                lighting: .bright,
                occlusion: .none,
                physicalCase: true,
                legalUseConfirmed: true
            ),
            groundTruth: EvidenceGroundTruth(
                kind: .staged,
                expectedCompletedCount: 2,
                expectedStepID: "main.ldr#2"
            ),
            estimate: EvidenceSessionFile.EstimateSummary(
                rankedStepIDs: ["main.ldr#2"],
                certainty: "high",
                insufficiencyCause: nil,
                latencyMilliseconds: 9_000
            ),
            analysisError: nil
        )
        try encoder.encode(session)
            .write(to: sessionDirectory.appendingPathComponent("session.json"))

        let row = EvidenceTraceRow(
            traceVersion: EvidenceSchema.traceVersion,
            traceID: traceID,
            sessionID: sessionID,
            pass: .finalist,
            passIndex: 0,
            captureID: captureID,
            captureAngle: "center",
            boardRelativePath: "boards/\(traceID.uuidString).jpg",
            tileRelativePaths: ["A": "tiles/\(traceID.uuidString)/A.jpg"],
            candidateStepIndices: ["A": 1],
            candidateStepIDs: ["A": "main.ldr#2"],
            prompt: "rank",
            schemaJSON: "{}",
            maxTokens: 192,
            rawOutput: #"{"status":"matched","ranking":["A"]}"#,
            decodeError: nil,
            termination: "accepted",
            generatedTokens: 12,
            latencyMilliseconds: 3_000,
            memoryFootprintBytes: 4_000_000_000,
            modelRevision: manifest.modelRevision,
            createdAt: .now
        )
        var line = try EvidenceSchema.encoder().encode(row)
        line.append(UInt8(ascii: "\n"))
        try line.write(to: sessionDirectory.appendingPathComponent("traces.ndjson"))

        // Optional by design: a session whose recovery never ran a geometric
        // pass has no fits.ndjson at all.
        if let fits {
            var payload = Data()
            for fit in fits {
                payload.append(try EvidenceSchema.encoder().encode(fit))
                payload.append(UInt8(ascii: "\n"))
            }
            try payload.write(to: sessionDirectory.appendingPathComponent("fits.ndjson"))
        }
        return bundleDirectory
    }
}
