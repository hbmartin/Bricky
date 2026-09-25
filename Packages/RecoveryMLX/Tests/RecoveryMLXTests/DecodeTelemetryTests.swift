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
