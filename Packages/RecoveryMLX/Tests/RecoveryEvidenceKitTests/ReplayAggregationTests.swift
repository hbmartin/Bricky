import XCTest
@testable import RecoveryEvidenceKit

final class ReplayAggregationTests: XCTestCase {
    private func row(slots: [String: String], indices: [String: Int] = [:], pass: RecoveryPassKind = .finalist) -> EvidenceTraceRow {
        EvidenceTraceRow(
            traceVersion: 1, traceID: UUID(), sessionID: UUID(), pass: pass, passIndex: 0, captureID: nil,
            captureAngle: "center", boardRelativePath: "b.jpg", tileRelativePaths: [:],
            candidateStepIndices: indices, candidateStepIDs: slots, prompt: "p", schemaJSON: "{}", maxTokens: 192,
            rawOutput: "{}", decodeError: nil, termination: "accepted", generatedTokens: 1, latencyMilliseconds: 1,
            memoryFootprintBytes: nil, modelRevision: "r", createdAt: .now
        )
    }

    private func checkRow(variant: RecoveryInferenceVariant?, alternates: [String: String]?) -> EvidenceTraceRow {
        EvidenceTraceRow(
            traceVersion: 1, traceID: UUID(), sessionID: UUID(), pass: .check, passIndex: 0, captureID: UUID(),
            captureAngle: "center", boardRelativePath: "b.jpg", tileRelativePaths: ["A": "tiles/t/A.jpg"],
            candidateStepIndices: ["A": 4], candidateStepIDs: ["A": "m#5"], prompt: "p", schemaJSON: "{}",
            maxTokens: 24, rawOutput: #"{"result":"complete"}"#, decodeError: nil, termination: "accepted",
            generatedTokens: 1, latencyMilliseconds: 1, memoryFootprintBytes: nil, modelRevision: "r",
            createdAt: .now, variant: variant, alternateTileRelativePaths: alternates
        )
    }

    func testCheckRowsRetargetOnlyToARecordedTarget() throws {
        // Rows from before the axis existed were guide-camera checks.
        let legacy = checkRow(variant: nil, alternates: nil)
        XCTAssertEqual(legacy.checkTarget, .guideCamera)
        XCTAssertEqual(legacy.retargeted(to: .guideCamera)?.tileRelativePaths, legacy.tileRelativePaths)
        XCTAssertNil(legacy.retargeted(to: .registered), "no registered render was recorded")

        let dual = checkRow(variant: nil, alternates: ["registered": "tiles/t/A.registered.jpg"])
        let registered = try XCTUnwrap(dual.retargeted(to: .registered))
        XCTAssertEqual(registered.checkTarget, .registered)
        XCTAssertEqual(registered.tileRelativePaths["A"], "tiles/t/A.registered.jpg")
        XCTAssertEqual(registered.alternateTileRelativePaths, ["guide_camera": "tiles/t/A.jpg"])
        XCTAssertEqual(registered.candidateStepIndices, dual.candidateStepIndices, "the target step never changes")
        // Round trip: back to the recorded tile.
        XCTAssertEqual(registered.retargeted(to: .guideCamera)?.tileRelativePaths["A"], "tiles/t/A.jpg")

        XCTAssertNil(row(slots: ["A": "m#1"]).retargeted(to: .guideCamera), "rank rows have no check target")
    }

    func testDecisionsCompareIgnoringWhitespace() throws {
        let legacy = try XCTUnwrap(ReplayDecision(rawOutput: #"{ "status": "matched", "ranking": ["B", "A"]}"#))
        let feedAll = try XCTUnwrap(ReplayDecision(rawOutput: #"{ "status": "matched" , "ranking": [ "B", "A" ] }"#))
        XCTAssertTrue(ReplayAggregation.decisionsMatch(legacy, feedAll))
        let different = try XCTUnwrap(ReplayDecision(rawOutput: #"{"status":"matched","ranking":["A","B"]}"#))
        XCTAssertFalse(ReplayAggregation.decisionsMatch(legacy, different))
        XCTAssertFalse(ReplayAggregation.decisionsMatch(nil, nil), "two undecodable outputs are not a match")
        XCTAssertNil(ReplayDecision(rawOutput: #"{ "status": "matc"#))
        XCTAssertEqual(ReplayDecision(rawOutput: #"{"result":"complete"}"#)?.result, "complete")
    }

    func testPassOutcomeSeparatesHierarchyMissesFromRankingErrors() {
        let finalists = row(slots: ["A": "m#7", "B": "m#8", "C": "m#9"])
        let matchedB = ReplayDecision(status: "matched", ranking: ["B", "A"])
        XCTAssertEqual(
            ReplayAggregation.passOutcome(row: finalists, decision: matchedB, expectedStepID: "m#8"),
            .init(truthSlot: "B", chosenSlot: "B", truthInCandidates: true, top1Correct: true)
        )
        // Truth absent from the board: not a ranking error.
        XCTAssertEqual(
            ReplayAggregation.passOutcome(row: finalists, decision: matchedB, expectedStepID: "m#2"),
            .init(truthSlot: nil, chosenSlot: "B", truthInCandidates: false, top1Correct: nil)
        )
        // "insufficient" chose nothing, whatever ranking it emitted.
        let insufficient = ReplayDecision(status: "insufficient", ranking: ["A", "B", "C"])
        XCTAssertEqual(
            ReplayAggregation.passOutcome(row: finalists, decision: insufficient, expectedStepID: "m#7"),
            .init(truthSlot: "A", chosenSlot: nil, truthInCandidates: true, top1Correct: false)
        )
        XCTAssertNil(ReplayAggregation.passOutcome(row: finalists, decision: matchedB, expectedStepID: nil).truthInCandidates)
    }

    func testExpectedCheckVerdictUsesPlanIndices() {
        // Plan index 4 is the fifth step: complete once five steps are.
        let check = row(slots: ["A": "m#5"], indices: ["A": 4], pass: .check)
        XCTAssertEqual(ReplayAggregation.expectedCheckVerdict(row: check, expectedCompletedCount: 5), "complete")
        XCTAssertEqual(ReplayAggregation.expectedCheckVerdict(row: check, expectedCompletedCount: 4), "incomplete")
        XCTAssertNil(ReplayAggregation.expectedCheckVerdict(row: check, expectedCompletedCount: nil))
    }
}
