import XCTest
@testable import RecoveryMLX

/// The pure pieces of the forked decoder, tested without a model.
final class DecodeTelemetryTests: XCTestCase {
    func testLegacyFeedsOnlyForcedTokensWhenThereAreAny() {
        XCTAssertEqual(FeedingPlan.tokensToFeed(sampled: 7, forced: [], policy: .legacy), [7])
        XCTAssertEqual(FeedingPlan.tokensToFeed(sampled: 7, forced: [8, 9], policy: .legacy), [8, 9])
    }

    func testFeedAllFeedsTheSampledTokenFirst() {
        XCTAssertEqual(FeedingPlan.tokensToFeed(sampled: 7, forced: [], policy: .feedAll), [7])
        XCTAssertEqual(FeedingPlan.tokensToFeed(sampled: 7, forced: [8, 9], policy: .feedAll), [7, 8, 9])
    }

    func testReadoutNormalizationIsASoftmax() {
        let probabilities = DecisionReadout.normalize([2, 1, 0])
        XCTAssertEqual(probabilities.reduce(0, +), 1, accuracy: 1e-12)
        XCTAssertEqual(probabilities[0] / probabilities[1], exp(1), accuracy: 1e-9)
        XCTAssertEqual(DecisionReadout.normalize([1_000, 1_000]), [0.5, 0.5], "large logits must not overflow")
        XCTAssertTrue(DecisionReadout.normalize([]).isEmpty)
    }

    func testLegalTokensReadsTheLSBFirstBitmask() {
        // Word 0 bits 1 and 31, word 1 bit 0 → tokens 1, 31, 32.
        let mask: [Int32] = [Int32(bitPattern: 0x8000_0002), 1]
        XCTAssertEqual(DecisionReadout.legalTokens(mask: mask, vocabSize: 64, limit: 8), [1, 31, 32])
        // Bits past the vocabulary are padding, not tokens.
        XCTAssertEqual(DecisionReadout.legalTokens(mask: mask, vocabSize: 32, limit: 8), [1, 31])
        // A structural position with more legal tokens than the limit is skipped.
        XCTAssertNil(DecisionReadout.legalTokens(mask: [-1], vocabSize: 32, limit: 8))
    }

    func testTelemetryKeysAreSnakeCase() throws {
        let telemetry = DecodeTelemetry(
            mode: .legacy, promptTokens: 1_100, imageTokens: 1_024, preprocessMilliseconds: 40,
            prefillMilliseconds: 900, decodeMilliseconds: 300, sampledTokens: 20, forcedTokens: 4,
            fedTokens: 22, droppedSampledTokens: 2, cacheOffset: 1_122, fastForwardDisagreements: 0
        )
        XCTAssertEqual(telemetry.emittedTokens, 24)
        let raw = String(decoding: try JSONEncoder().encode(telemetry), as: UTF8.self)
        for key in ["prompt_tokens", "image_tokens", "prefill_ms", "dropped_sampled_tokens", "cache_offset"] {
            XCTAssertTrue(raw.contains("\"\(key)\""), key)
        }
    }
}

final class SlotUniquenessTests: XCTestCase {
    private let allowed: Set<Character> = ["A", "B", "C"]
    private let texts = [0: "A", 1: "B", 2: "C", 3: "A\"", 4: "\"", 5: "]", 6: "matched"]
    private var index: [Character: [Int]] {
        SlotUniqueness.letterTokens(vocabSize: texts.count, letters: allowed, text: { self.texts[$0]! })
    }

    func testNothingIsMaskedBeforeTheFirstLetter() {
        XCTAssertEqual(SlotUniqueness.blockedTokens(index: index, emitted: []), [])
    }

    func testEmittedLettersAreMaskedWhereverTheyAppear() {
        // Token 3 ("A\"") would repeat A just as token 0 would.
        XCTAssertEqual(SlotUniqueness.blockedTokens(index: index, emitted: ["A"]), [0, 3])
    }

    func testStructuralTokensAndLowercaseAreNeverSlotLetters() {
        XCTAssertEqual(SlotUniqueness.slotLetters(in: "matched", allowed: allowed), [])
        let blocked = SlotUniqueness.blockedTokens(index: index, emitted: ["A", "B"])
        XCTAssertFalse(blocked.contains(4))
        XCTAssertFalse(blocked.contains(5))
        XCTAssertFalse(blocked.contains(6))
    }

    /// The bug this index fixes: after `[` or `,` the legal set holds
    /// whitespace runs as well as merged quote+letter tokens, so it is
    /// larger than the readout cap. Masking must not depend on that cap.
    func testMaskingHoldsWhenTheLegalSetExceedsTheReadoutCap() {
        let whitespace = (0..<100).map { _ in " " }
        let vocab = whitespace + ["\"A", "\"B", "\"C"]
        let index = SlotUniqueness.letterTokens(vocabSize: vocab.count, letters: allowed, text: { vocab[$0] })
        var mask = [Int32](repeating: 0, count: (vocab.count + 31) / 32)
        for id in vocab.indices { mask[id / 32] |= Int32(bitPattern: 1 << UInt32(id % 32)) }
        XCTAssertNil(DecisionReadout.legalTokens(mask: mask, vocabSize: vocab.count, limit: 64), "the readout gives up here")
        let blocked = SlotUniqueness.blockedTokens(index: index, emitted: ["A", "B"])
        XCTAssertEqual(blocked, [100, 101])
        XCTAssertEqual(SlotUniqueness.legalCount(blocked, mask: mask), 2)
    }

    func testVariantIDNamesUniqueSlotsAndDecodesOldJSON() throws {
        XCTAssertEqual(RecoveryInferenceVariant(uniqueSlots: true).id, "unique_slots")
        let old = try JSONDecoder().decode(RecoveryInferenceVariant.self, from: Data(#"{"decode":"feed_all","vote":"borda_dedup"}"#.utf8))
        XCTAssertFalse(old.uniqueSlots)
        XCTAssertEqual(old.id, "decode=feed_all")
    }
}
