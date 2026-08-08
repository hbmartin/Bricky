import RecoveryMLX
import XCTest
@testable import Bricky

final class RecoveryBenchmarkWriterTests: XCTestCase {
    /// Mirrors REQUIRED_FIELDS in Tools/RecoveryEvaluation/score_results.py.
    private static let scorerRequiredFields: Set<String> = [
        "schema_version", "fixture_id", "instruction_sha256", "pyldraw3_version",
        "part_pack_version", "expected_step_id", "candidate_slots",
        "board_relative_paths", "camera_metadata", "expected_step_index",
        "ranked_step_ids", "certainty", "estimator_method", "device_model",
        "operating_system", "latency_ms", "memory_peak_bytes"
    ]

    /// Mirrors RELEASE_FIELDS in score_results.py.
    private static let scorerReleaseFields: Set<String> = [
        "physical_case", "authored_model_id", "legal_use_confirmed",
        "lighting_condition", "capture_angle", "occlusion_condition"
    ]

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("benchmark-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testBenchmarkRowSatisfiesScorerContract() async throws {
        let recorder = makeRecorder(staged: StagedFixtureDeclaration(
            expectedCompletedCount: 8,
            lighting: .dim,
            occlusion: .partial,
            physicalCase: true,
            legalUseConfirmed: true
        ))
        let capture = try makeCapture()
        await recorder.recordCaptures([capture])
        for angle in ["left", "center", "right"] {
            try await recordFinalistPass(recorder: recorder, capture: capture, angle: angle)
        }
        await recorder.finalize(
            estimate: RecoveryEstimate(
                rankedStepIDs: ["main.ldr#8", "main.ldr#7", "main.ldr#9"],
                certainty: .high,
                modelRevision: "test-revision",
                latencyMilliseconds: 12_000,
                captureIDs: [capture.id],
                insufficiencyCause: nil,
                method: .composite
            ),
            analysisError: nil,
            groundTruth: EvidenceGroundTruth(
                kind: .staged,
                expectedCompletedCount: 8,
                expectedStepID: "main.ldr#8",
                confirmedCompletedCount: 8,
                confirmedAt: .now
            )
        )
        await recorder.writeBenchmarkRow(inputs: RecoveryBenchmarkInputs(
            expectedCompletedCount: 8,
            expectedStepID: "main.ldr#8",
            stepNumbersByID: ["main.ldr#0": 0, "main.ldr#7": 7, "main.ldr#8": 8, "main.ldr#9": 9]
        ))

        let row = try loadBenchmarkRow(recorder: recorder)
        let keys = Set(row.keys)
        XCTAssertTrue(
            Self.scorerRequiredFields.isSubset(of: keys),
            "missing required: \(Self.scorerRequiredFields.subtracting(keys).sorted())"
        )
        XCTAssertTrue(
            Self.scorerReleaseFields.isSubset(of: keys),
            "missing release: \(Self.scorerReleaseFields.subtracting(keys).sorted())"
        )
        XCTAssertEqual(row["schema_version"] as? Int, 1)
        // Same semantics as fixtures/example-device-results.ndjson: authored
        // step numbers, 0 = step zero.
        XCTAssertEqual(row["expected_step_index"] as? Int, 8)
        XCTAssertEqual(row["expected_step_id"] as? String, "main.ldr#8")
        XCTAssertEqual(row["top_step_index"] as? Int, 8)
        XCTAssertEqual(row["certainty"] as? String, "high")
        // From the estimate, not the session header: the header records only
        // which VLM was loadable when the session opened.
        XCTAssertEqual(row["estimator_method"] as? String, "composite")
        XCTAssertEqual(row["model_revision"] as? String, "test-revision")
        XCTAssertEqual(row["latency_ms"] as? Int, 12_000)
        XCTAssertEqual(
            row["candidate_slots"] as? [String: String],
            ["A": "main.ldr#7", "B": "main.ldr#8", "C": "main.ldr#9"]
        )
        XCTAssertEqual((row["board_relative_paths"] as? [String])?.count, 3)
        XCTAssertEqual(row["lighting_condition"] as? String, "dim")
        XCTAssertEqual(row["occlusion_condition"] as? String, "partial")
        XCTAssertEqual(row["legal_use_confirmed"] as? Bool, true)
        XCTAssertEqual(row["capture_angle"] as? String, "center")
        let camera = try XCTUnwrap((row["camera_metadata"] as? [[String: Double]])?.first)
        XCTAssertEqual(camera["fx"], 1200)
        XCTAssertEqual(camera["cx"], 640)
        XCTAssertEqual(camera["width"], 1920)
    }

    func testStepZeroUsesIndexZero() async throws {
        let recorder = makeRecorder(staged: nil)
        let capture = try makeCapture()
        await recorder.recordCaptures([capture])
        try await recordFinalistPass(recorder: recorder, capture: capture, angle: "center")
        await recorder.finalize(
            estimate: RecoveryEstimate(
                rankedStepIDs: ["main.ldr#0"],
                certainty: .medium,
                modelRevision: "test-revision",
                latencyMilliseconds: 9_000,
                captureIDs: [capture.id],
                insufficiencyCause: nil,
                method: .geometric
            ),
            analysisError: nil,
            groundTruth: EvidenceGroundTruth(kind: .confirmed, expectedCompletedCount: 0, expectedStepID: "main.ldr#0")
        )
        await recorder.writeBenchmarkRow(inputs: RecoveryBenchmarkInputs(
            expectedCompletedCount: 0,
            expectedStepID: "main.ldr#0",
            stepNumbersByID: ["main.ldr#0": 0, "main.ldr#1": 1]
        ))
        let row = try loadBenchmarkRow(recorder: recorder)
        XCTAssertEqual(row["expected_step_index"] as? Int, 0)
        XCTAssertEqual(row["expected_step_id"] as? String, "main.ldr#0")
        XCTAssertEqual(row["top_step_index"] as? Int, 0)
    }

    func testUnlabeledSessionEmitsNoBenchmarkRow() async throws {
        let recorder = makeRecorder(staged: nil)
        let capture = try makeCapture()
        await recorder.recordCaptures([capture])
        try await recordFinalistPass(recorder: recorder, capture: capture, angle: "center")
        await recorder.finalize(estimate: nil, analysisError: "boom", groundTruth: .unlabeled)
        await recorder.writeBenchmarkRow(inputs: RecoveryBenchmarkInputs(
            expectedCompletedCount: 0, expectedStepID: "main.ldr#0", stepNumbersByID: [:]
        ))
        let benchmark = root
            .appendingPathComponent(RecoveryEvidenceRecorder.directoryName)
            .appendingPathComponent(recorder.sessionID.uuidString)
            .appendingPathComponent("benchmark.ndjson")
        XCTAssertFalse(FileManager.default.fileExists(atPath: benchmark.path))
    }

    // MARK: - Fixtures

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

    private func makeCapture() throws -> RecoveryCapture {
        let captures = root.appendingPathComponent("RecoveryCaptures", isDirectory: true)
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        let id = UUID()
        try Data("capture".utf8).write(to: captures.appendingPathComponent("\(id.uuidString).jpg"))
        return RecoveryCapture(
            id: id,
            imageRelativePath: "RecoveryCaptures/\(id.uuidString).jpg",
            cameraTransform: Array(repeating: 0, count: 16),
            cameraIntrinsics: [1200, 0, 0, 0, 1200, 0, 640, 360, 1],
            cameraImageResolution: [1920, 1440],
            alignmentID: UUID(),
            angle: .center,
            capturedAt: .now
        )
    }

    private func recordFinalistPass(recorder: RecoveryEvidenceRecorder, capture: RecoveryCapture, angle: String) async throws {
        let board = root.appendingPathComponent("board-\(angle).jpg")
        try Data("jpeg".utf8).write(to: board)
        var passCapture = capture
        if angle != "center" {
            passCapture = RecoveryCapture(
                id: UUID(),
                imageRelativePath: capture.imageRelativePath,
                cameraTransform: capture.cameraTransform,
                cameraIntrinsics: capture.cameraIntrinsics,
                cameraImageResolution: capture.cameraImageResolution,
                alignmentID: capture.alignmentID,
                angle: CaptureAngle(rawValue: angle) ?? .center,
                capturedAt: capture.capturedAt
            )
        }
        await recorder.recordPass(
            pass: .finalist,
            passIndex: 0,
            capture: passCapture,
            candidates: [
                .init(slot: "A", stepIndex: 6, stepID: "main.ldr#7", jpegData: Data("a".utf8)),
                .init(slot: "B", stepIndex: 7, stepID: "main.ldr#8", jpegData: Data("b".utf8)),
                .init(slot: "C", stepIndex: 8, stepID: "main.ldr#9", jpegData: Data("c".utf8))
            ],
            boardURL: board,
            prompt: "rank",
            trace: MLXGenerationTrace(
                rawOutput: #"{"status":"matched","ranking":["B","A","C"]}"#,
                decodeErrorDescription: nil,
                generatedTokens: 20,
                termination: .accepted,
                latencyMilliseconds: 4_000,
                maxTokens: 192,
                schemaJSON: "{}"
            )
        )
    }

    private func loadBenchmarkRow(recorder: RecoveryEvidenceRecorder) throws -> [String: Any] {
        let url = root
            .appendingPathComponent(RecoveryEvidenceRecorder.directoryName)
            .appendingPathComponent(recorder.sessionID.uuidString)
            .appendingPathComponent("benchmark.ndjson")
        let line = try XCTUnwrap(
            String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n")
                .first
        )
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }
}
