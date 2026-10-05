import RecoveryMLX
import XCTest
@testable import Bricky

/// Device sessions with photo checks write `check.ndjson`: one `vlm_check`
/// row per labeled check, in the shape `score_results.py` scores.
final class VLMCheckRowWriterTests: XCTestCase {
    /// Mirrors the fields `score_vlm_check` and the release preflight read.
    private static let scorerFields: Set<String> = [
        "kind", "provenance", "fixture_id", "expected_verdict", "produced_verdict",
        "latency_ms", "device_model", "label_kind", "authored_model_id",
        "physical_case", "legal_use_confirmed"
    ]

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("check-rows-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testStagedShortOfStepYieldsIncomplete() async throws {
        let recorder = makeRecorder(staged: Self.staged(completed: 5))
        // The checked step is plan index 6 (authored step 7); 5 are built.
        try await recordPass(recorder, pass: .check, stepIndex: 6, output: #"{"result":"complete"}"#)
        await recorder.finalize(estimate: nil, analysisError: nil, groundTruth: Self.stagedTruth(completed: 5))

        let rows = try loadRows(recorder)
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertTrue(Self.scorerFields.isSubset(of: Set(row.keys)), "missing: \(Self.scorerFields.subtracting(row.keys).sorted())")
        XCTAssertEqual(row["kind"] as? String, "vlm_check")
        XCTAssertEqual(row["provenance"] as? String, "device")
        XCTAssertEqual(row["expected_verdict"] as? String, "incomplete")
        XCTAssertEqual(row["produced_verdict"] as? String, "complete", "a false complete the scorer must see")
        XCTAssertEqual(row["decode_failed"] as? Bool, false)
        XCTAssertEqual(row["label_kind"] as? String, "staged")
        XCTAssertEqual(row["physical_case"] as? Bool, true)
        XCTAssertEqual(row["legal_use_confirmed"] as? Bool, true)
        XCTAssertEqual(row["step_index"] as? Int, 6)
        XCTAssertEqual(row["check_target"] as? String, "guide_camera")
    }

    func testDecodeFailureIsUncertainAndFlagged() async throws {
        let recorder = makeRecorder(staged: Self.staged(completed: 7))
        try await recordPass(recorder, pass: .check, stepIndex: 6, output: "not json")
        await recorder.finalize(estimate: nil, analysisError: nil, groundTruth: Self.stagedTruth(completed: 7))

        let row = try XCTUnwrap(try loadRows(recorder).first)
        XCTAssertEqual(row["expected_verdict"] as? String, "complete")
        XCTAssertEqual(row["produced_verdict"] as? String, "uncertain")
        XCTAssertEqual(row["decode_failed"] as? Bool, true)
    }

    func testUnlabeledWritesNothing() async throws {
        let recorder = makeRecorder(staged: nil)
        try await recordPass(recorder, pass: .check, stepIndex: 6, output: #"{"result":"complete"}"#)
        await recorder.finalize(estimate: nil, analysisError: nil, groundTruth: .unlabeled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkRowsURL(recorder).path))
    }

    func testRecoveryOnlySessionWritesNothing() async throws {
        let recorder = makeRecorder(staged: Self.staged(completed: 7))
        try await recordPass(recorder, pass: .finalist, stepIndex: 6, output: #"{"status":"matched","ranking":["A"]}"#)
        await recorder.finalize(estimate: nil, analysisError: nil, groundTruth: Self.stagedTruth(completed: 7))
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkRowsURL(recorder).path))
    }

    func testConfirmedLabelsAreMarkedSo() async throws {
        let recorder = makeRecorder(staged: nil)
        try await recordPass(recorder, pass: .check, stepIndex: 6, output: #"{"result":"complete"}"#)
        await recorder.finalize(
            estimate: nil, analysisError: nil,
            groundTruth: EvidenceGroundTruth(kind: .confirmed, expectedCompletedCount: 7, expectedStepID: "main.ldr#7")
        )
        let row = try XCTUnwrap(try loadRows(recorder).first)
        XCTAssertEqual(row["label_kind"] as? String, "confirmed")
        XCTAssertNil(row["physical_case"] as? Bool)
    }

    // MARK: - Fixtures

    private static func staged(completed: Int) -> StagedFixtureDeclaration {
        StagedFixtureDeclaration(
            expectedCompletedCount: completed, lighting: .bright, occlusion: .none,
            physicalCase: true, legalUseConfirmed: true
        )
    }

    private static func stagedTruth(completed: Int) -> EvidenceGroundTruth {
        EvidenceGroundTruth(kind: .staged, expectedCompletedCount: completed, expectedStepID: "main.ldr#\(completed)")
    }

    private func makeRecorder(staged: StagedFixtureDeclaration?) -> RecoveryEvidenceRecorder {
        RecoveryEvidenceRecorder(
            root: root,
            instructionSHA256: String(repeating: "0", count: 64),
            authoredModelID: UUID(),
            modelTitle: "Test Model",
            stepCount: 12,
            staged: staged
        )
    }

    private func recordPass(
        _ recorder: RecoveryEvidenceRecorder, pass: RecoveryPassKind, stepIndex: Int, output: String
    ) async throws {
        let board = root.appendingPathComponent("board-\(UUID().uuidString).jpg")
        try Data("jpeg".utf8).write(to: board)
        await recorder.recordPass(
            pass: pass,
            passIndex: 0,
            capture: nil,
            candidates: [.init(slot: "A", stepIndex: stepIndex, stepID: "main.ldr#\(stepIndex + 1)", jpegData: Data("a".utf8))],
            boardURL: board,
            prompt: "check",
            trace: MLXGenerationTrace(
                rawOutput: output,
                decodeErrorDescription: nil,
                generatedTokens: 6,
                termination: .accepted,
                latencyMilliseconds: 2_500,
                maxTokens: 48,
                schemaJSON: "{}"
            )
        )
    }

    private func checkRowsURL(_ recorder: RecoveryEvidenceRecorder) -> URL {
        root
            .appendingPathComponent(RecoveryEvidenceRecorder.directoryName)
            .appendingPathComponent(recorder.sessionID.uuidString)
            .appendingPathComponent(RecoveryEvidenceRecorder.checkRowsFilename)
    }

    private func loadRows(_ recorder: RecoveryEvidenceRecorder) throws -> [[String: Any]] {
        try String(contentsOf: checkRowsURL(recorder), encoding: .utf8)
            .split(separator: "\n")
            .map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
    }
}
