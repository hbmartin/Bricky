import Tokenizers
import XCTest
@testable import RecoveryMLX

/// Probe scoring reads the distribution at a token boundary, so the
/// canonical prefixes must tokenize with boundaries exactly where the
/// decisions start. Needs only the tokenizer files of the pinned revision.
final class QwenTokenizationTests: XCTestCase {
    private func tokenizer() async throws -> any Tokenizers.Tokenizer {
        let model = try TestBoards.modelDirectory()
        return try await Tokenizers.AutoTokenizer.from(modelFolder: model)
    }

    func testDecisionsStartOnTokenBoundaries() async throws {
        let tokenizer = try await tokenizer()
        let rank = RecoveryProbe.Decision.rank(slotCount: 8, letters: ["A", "B", "C", "D", "E", "F", "G", "H"])
        let rankTokens = tokenizer.encode(text: rank.prefix, addSpecialTokens: false)
        let marker = try XCTUnwrap(rank.statusMarker)
        XCTAssertTrue(
            (1...rankTokens.count).contains { tokenizer.decode(tokens: Array(rankTokens[..<$0])) == marker },
            "no boundary after \(marker)"
        )
        // Each letter appended to the prefix is one more token, and the
        // prefix's own tokens are unchanged: the slot readout sees exactly
        // the letter distribution.
        for letter in rank.options {
            let full = tokenizer.encode(text: rank.prefix + letter, addSpecialTokens: false)
            XCTAssertEqual(Array(full.prefix(rankTokens.count)), rankTokens, letter)
            XCTAssertEqual(full.count, rankTokens.count + 1, "\(letter) is not a single token after the prefix")
        }
        let check = RecoveryProbe.Decision.check
        let checkTokens = tokenizer.encode(text: check.prefix, addSpecialTokens: false)
        for verdict in check.options {
            let full = tokenizer.encode(text: check.prefix + verdict, addSpecialTokens: false)
            XCTAssertEqual(Array(full.prefix(checkTokens.count)), checkTokens, verdict)
        }
    }
}

final class ProbeScoringModelTests: XCTestCase {
    private static let runtime = MLXRecoveryRuntime()

    func testProbeReadsDistributionsFromOnePrefill() async throws {
        let model = try TestBoards.modelDirectory()
        let scratch = FileManager.default.temporaryDirectory
        let rank = try await Self.runtime.rankWithTrace(
            imageURL: try TestBoards.board(slots: 3, in: scratch),
            prompt: TestBoards.rankPrompt, candidateCount: 3, modelDirectory: model, scoring: .probe
        )
        let probe = try XCTUnwrap(rank.trace.probe)
        print("probe rank 3: \(rank.trace.rawOutput) p_insufficient=\(probe.pInsufficient ?? -1) slots=\(probe.options) \(rank.trace.latencyMilliseconds) ms")
        XCTAssertEqual(rank.trace.termination, .readoutComplete)
        XCTAssertEqual(rank.trace.generatedTokens, 0)
        XCTAssertEqual(probe.options.values.reduce(0, +), 1, accuracy: 1e-6)
        XCTAssertEqual(Set(probe.options.keys), ["A", "B", "C"])
        XCTAssertNotNil(probe.pInsufficient)
        XCTAssertNotNil(rank.output, "the synthesized answer decodes as a rank")

        let check = try await Self.runtime.checkStepWithTrace(
            imageURL: try TestBoards.board(slots: 1, in: scratch),
            prompt: TestBoards.checkPrompt, modelDirectory: model, scoring: .probe
        )
        let verdicts = try XCTUnwrap(check.trace.probe)
        print("probe check: \(check.trace.rawOutput) \(verdicts.options)")
        XCTAssertEqual(Set(verdicts.options.keys), ["complete", "incomplete", "uncertain"])
        XCTAssertEqual(check.output?.result, verdicts.ranked.first)
    }
}
