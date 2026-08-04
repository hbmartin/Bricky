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

    /// Builds a minimal on-disk bundle with one staged session and one trace.
    private func makeBundle(bundleVersion: Int = EvidenceSchema.bundleVersion) throws -> URL {
        let bundleDirectory = root.appendingPathComponent("bundle", isDirectory: true)
        let sessionID = UUID()
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
            modelID: "mlx-community/Qwen2.5-VL-3B-Instruct-4bit",
            modelRevision: "46d4cf06a06ffc1a766c214174f9cbed2f45bcab",
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
        return bundleDirectory
    }
}
