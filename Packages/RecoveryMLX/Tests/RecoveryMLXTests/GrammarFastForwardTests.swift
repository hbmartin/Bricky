import MLXGuidedGeneration
import MLXLMCommon
import XCTest
@testable import RecoveryMLX

/// What the pinned xgrammar actually does with Bricky's schemas, proven on a
/// toy vocabulary without weights or a GPU. These pin the two §2a findings:
/// the rank grammar accepts repeated letters (its `uniqueItems` is ignored),
/// and a sampled token before a multi-token forced span is not among the
/// fast-forward tokens — so a loop that feeds only those drops it.
final class GrammarFastForwardTests: XCTestCase {
    /// Single characters plus the whole-word tokens a BPE vocab would have.
    static let vocab: [String] = {
        let characters = Array(#"{}[]":, abcdefghijklmnopqrstuvwxyzABCDEFGH"#).map(String.init)
        return characters + ["status", "ranking", "matched", "insufficient", "result", "complete", "</s>"]
    }()

    /// Greedy longest-match tokenizer over `vocab`, standing in for the host
    /// tokenizer xgrammar uses to re-encode fast-forward strings.
    struct ToyTokenizer: MLXLMCommon.Tokenizer {
        func encode(text: String, addSpecialTokens: Bool) -> [Int] {
            var ids: [Int] = []
            var rest = Substring(text)
            while !rest.isEmpty {
                let match = GrammarFastForwardTests.vocab.enumerated()
                    .filter { rest.hasPrefix($0.element) }
                    .max { $0.element.count < $1.element.count }
                guard let match else { break }
                ids.append(match.offset)
                rest = rest.dropFirst(match.element.count)
            }
            return ids
        }

        func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
            tokenIds.map { GrammarFastForwardTests.vocab[$0] }.joined()
        }

        func convertTokenToId(_ token: String) -> Int? { GrammarFastForwardTests.vocab.firstIndex(of: token) }
        func convertIdToToken(_ id: Int) -> String? { GrammarFastForwardTests.vocab.indices.contains(id) ? GrammarFastForwardTests.vocab[id] : nil }
        var bosToken: String? { nil }
        var eosToken: String? { "</s>" }
        var unknownToken: String? { nil }

        func applyChatTemplate(
            messages: [[String: any Sendable]],
            tools: [[String: any Sendable]]?,
            additionalContext: [String: any Sendable]?
        ) throws -> [Int] { [] }
    }

    private func constraint(schema: String) throws -> GrammarConstraint {
        let tokenizer = try GrammarTokenizer(
            vocab: Self.vocab,
            vocabType: .raw,
            eosTokenId: Int32(Self.vocab.firstIndex(of: "</s>")!)
        )
        return try GrammarConstraint(tokenizer: tokenizer, jsonSchema: schema, fastForward: true, hostTokenizer: ToyTokenizer())
    }

    private func allows(_ mask: MaskResult, _ token: Int) -> Bool {
        guard mask.needsApply else { return true }
        return (UInt32(bitPattern: mask.mask[token / 32]) >> (token % 32)) & 1 == 1
    }

    /// Drives the grammar through `text` the way the decode loop does:
    /// sample the longest legal token, commit it, then consume whatever the
    /// grammar fast-forwarded. Returns the per-step commits.
    @discardableResult
    private func drive(
        _ text: String,
        schema: String
    ) throws -> (accepted: Bool, steps: [(sampled: String, forced: [String])]) {
        let grammar = try constraint(schema: schema)
        var rest = Substring(text)
        var steps: [(sampled: String, forced: [String])] = []
        while !rest.isEmpty {
            let mask = try grammar.computeMask()
            let candidate = Self.vocab.enumerated()
                .filter { rest.hasPrefix($0.element) && allows(mask, $0.offset) }
                .max { $0.element.count < $1.element.count }
            guard let candidate else { return (false, steps) }
            let result = try grammar.commitToken(Int32(candidate.offset))
            rest = rest.dropFirst(candidate.element.count)
            let forced = result.tokens.map { Self.vocab[Int($0)] }
            for piece in forced {
                guard rest.hasPrefix(piece) else { return (false, steps) }
                rest = rest.dropFirst(piece.count)
            }
            steps.append((candidate.element, forced))
            if result.isTerminated { break }
        }
        let eos = Self.vocab.firstIndex(of: "</s>")!
        let final = try grammar.computeMask()
        return (rest.isEmpty && (final.isTerminated || allows(final, eos)), steps)
    }

    func testRankGrammarAcceptsRepeatedSlots() throws {
        // The schema asks for uniqueItems; the pinned xgrammar ignores it.
        let schema = MLXRecoveryRuntime.rankSchema(slotCount: 3)
        XCTAssertTrue(schema.contains(#""uniqueItems":true"#))
        XCTAssertTrue(try drive(#"{"status":"matched","ranking":["B","B","B"]}"#, schema: schema).accepted)
        XCTAssertTrue(try drive(#"{"status":"matched","ranking":["B","A","C"]}"#, schema: schema).accepted)
        XCTAssertFalse(try drive(#"{"status":"matched","ranking":["D"]}"#, schema: schema).accepted, "D has no tile on a 3-slot board")
    }

    private func id(_ piece: String) -> Int32 { Int32(Self.vocab.firstIndex(of: piece)!) }

    func testForcedSpansExcludeTheSampledTokenBeforeThem() throws {
        let (accepted, steps) = try drive(
            #"{"status":"matched","ranking":["B","C"]}"#,
            schema: MLXRecoveryRuntime.rankSchema(slotCount: 3)
        )
        XCTAssertTrue(accepted)
        // The opening quote of each key is sampled; the key name is forced.
        let spans = steps.filter { !$0.forced.isEmpty }
        XCTAssertEqual(spans.map(\.sampled), ["\"", "\""])
        XCTAssertEqual(spans.map(\.forced), [["status"], ["ranking"]])
        for span in spans {
            let forced = span.forced.map(id)
            // Legacy feeding (the pinned loop) feeds only the forced span, so
            // the quote before it never reaches the KV cache.
            XCTAssertEqual(FeedingPlan.tokensToFeed(sampled: id(span.sampled), forced: forced, policy: .legacy), forced)
            XCTAssertEqual(
                FeedingPlan.tokensToFeed(sampled: id(span.sampled), forced: forced, policy: .feedAll),
                [id(span.sampled)] + forced
            )
        }
        // No forced span follows a slot letter, so the letters themselves do
        // reach the cache: the context before them is what is corrupted.
        let letters = steps.filter { ["B", "C"].contains($0.sampled) }
        XCTAssertEqual(letters.count, 2)
        XCTAssertTrue(letters.allSatisfy(\.forced.isEmpty))
    }

    func testCheckGrammarAcceptsOnlyItsVerdicts() throws {
        let schema = VerdictSchemasV1.checkGrammarJSON
        XCTAssertTrue(try drive(#"{"result":"complete"}"#, schema: schema).accepted)
        XCTAssertFalse(try drive(#"{"result":"done"}"#, schema: schema).accepted)
    }
}
