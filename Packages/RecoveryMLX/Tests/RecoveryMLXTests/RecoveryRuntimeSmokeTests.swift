import XCTest
@testable import RecoveryMLX

/// End-to-end inference on the pinned weights. Skipped unless
/// `BRICKY_MODEL_DIR` is set. Before these existed the pinned VLM had never
/// run: its stale shard index stopped it loading, and the grammar bridge's
/// clone() failed every call, so on-device admission could only reject.
final class RecoveryRuntimeSmokeTests: XCTestCase {
    private static let runtime = MLXRecoveryRuntime()

    func testRankAndCheckProduceGrammarValidOutput() async throws {
        let model = try TestBoards.modelDirectory()
        let scratch = FileManager.default.temporaryDirectory
        let rank = try await Self.runtime.rankWithTrace(
            imageURL: try TestBoards.board(slots: 3, in: scratch),
            prompt: TestBoards.rankPrompt,
            candidateCount: 3,
            modelDirectory: model
        )
        print("rank: \(rank.trace.rawOutput) (\(rank.trace.latencyMilliseconds) ms)")
        XCTAssertEqual(rank.trace.termination, .accepted)
        let output = try XCTUnwrap(rank.output, rank.trace.decodeErrorDescription ?? "")
        XCTAssertTrue(["matched", "insufficient"].contains(output.status))
        XCTAssertTrue(output.ranking.allSatisfy { ["A", "B", "C"].contains($0) })

        let check = try await Self.runtime.checkStepWithTrace(
            imageURL: try TestBoards.board(slots: 1, in: scratch),
            prompt: TestBoards.checkPrompt,
            modelDirectory: model
        )
        print("check: \(check.trace.rawOutput) (\(check.trace.latencyMilliseconds) ms)")
        XCTAssertEqual(check.trace.termination, .accepted)
        XCTAssertNotNil(check.output)
    }
}
