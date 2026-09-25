import XCTest
@testable import RecoveryMLX

/// The forked decoder against the pinned upstream loop, on real weights.
/// Skipped unless `BRICKY_MODEL_DIR` is set.
///
/// Two claims are proven here, both needed before any feeding A/B can be
/// trusted: in `legacy` mode the fork is byte-identical to upstream, so
/// evidence recorded before the fork replays unchanged; and upstream's
/// feeding really does drop sampled tokens from the KV cache (the roadmap's
/// §2a finding, measured on the real tokenizer rather than reasoned about).
final class RecoveryDecoderParityTests: XCTestCase {
    private static let runtime = MLXRecoveryRuntime()
    private let scratch = FileManager.default.temporaryDirectory

    func testLegacyForkIsByteIdenticalToUpstreamForRanking() async throws {
        let model = try TestBoards.modelDirectory()
        for slots in [3, 8] {
            let board = try TestBoards.board(slots: slots, in: scratch)
            let upstream = try await Self.runtime.rankWithTrace(
                imageURL: board, prompt: TestBoards.rankPrompt, candidateCount: slots, modelDirectory: model, decode: .upstream
            )
            let legacy = try await Self.runtime.rankWithTrace(
                imageURL: board, prompt: TestBoards.rankPrompt, candidateCount: slots, modelDirectory: model, decode: .legacy
            )
            XCTAssertEqual(legacy.trace.rawOutput, upstream.trace.rawOutput, "\(slots) slots")
            XCTAssertEqual(legacy.trace.generatedTokens, upstream.trace.generatedTokens, "\(slots) slots")
            XCTAssertEqual(legacy.trace.termination, upstream.trace.termination, "\(slots) slots")
            XCTAssertNil(upstream.trace.telemetry)

            let telemetry = try XCTUnwrap(legacy.trace.telemetry)
            print("rank \(slots): \(legacy.trace.rawOutput)\n  \(telemetry)")
            // The cache holds the prompt plus exactly what was fed.
            XCTAssertEqual(telemetry.cacheOffset, telemetry.promptTokens + telemetry.fedTokens)
            XCTAssertEqual(telemetry.imageTokens, 1_024, "a 1024² board is one token per 32×32 block")
            XCTAssertEqual(telemetry.emittedTokens, legacy.trace.generatedTokens)
            // §2a, measured: sampled tokens were emitted but never fed.
            XCTAssertGreaterThan(telemetry.droppedSampledTokens, 0)
            XCTAssertLessThan(telemetry.fedTokens, telemetry.emittedTokens - 1)
        }
    }

    func testLegacyForkIsByteIdenticalToUpstreamForStepCheck() async throws {
        let model = try TestBoards.modelDirectory()
        let board = try TestBoards.board(slots: 1, in: scratch)
        let upstream = try await Self.runtime.checkStepWithTrace(
            imageURL: board, prompt: TestBoards.checkPrompt, modelDirectory: model, decode: .upstream
        )
        let legacy = try await Self.runtime.checkStepWithTrace(
            imageURL: board, prompt: TestBoards.checkPrompt, modelDirectory: model, decode: .legacy
        )
        XCTAssertEqual(legacy.trace.rawOutput, upstream.trace.rawOutput)
        XCTAssertEqual(legacy.trace.generatedTokens, upstream.trace.generatedTokens)
        let readouts = try XCTUnwrap(legacy.trace.readouts)
        print("check: \(legacy.trace.rawOutput)")
        for readout in readouts {
            print("  @\(readout.position): \(readout.candidates.prefix(4).map { "\($0.text.debugDescription)=\(String(format: "%.3f", $0.probability))" })")
        }
        XCTAssertFalse(readouts.isEmpty, "the verdict enum is a small-legal-set decision")
    }

    func testFeedAllKeepsEverySampledTokenInTheCache() async throws {
        let model = try TestBoards.modelDirectory()
        let response = try await Self.runtime.rankWithTrace(
            imageURL: try TestBoards.board(slots: 3, in: scratch),
            prompt: TestBoards.rankPrompt, candidateCount: 3, modelDirectory: model, decode: .feedAll
        )
        let telemetry = try XCTUnwrap(response.trace.telemetry)
        print("feed_all rank 3: \(response.trace.rawOutput)\n  \(telemetry)")
        XCTAssertEqual(response.trace.termination, .accepted)
        XCTAssertEqual(telemetry.droppedSampledTokens, 0)
        XCTAssertEqual(telemetry.cacheOffset, telemetry.promptTokens + telemetry.fedTokens)
        // Everything emitted is fed except the token that completed the
        // grammar, which the loop never needs to feed.
        XCTAssertLessThanOrEqual(telemetry.emittedTokens - telemetry.fedTokens, 1)
    }
}
