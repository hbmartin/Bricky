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
