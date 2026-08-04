import RecoveryMLX
import XCTest
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

    private func makeCapture() throws -> RecoveryCapture {
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
            angle: .center,
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
