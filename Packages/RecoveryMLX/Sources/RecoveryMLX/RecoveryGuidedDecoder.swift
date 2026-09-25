// Forked from mlx-swift-lm `Libraries/MLXGuidedGeneration/GuidedGenerationLoop.swift`
// at d2424294a6c3bbd0de37a0761d80efc05e6813dd.
// Copyright © 2026 Apple Inc. Used under the MIT License.
// Modifications for Bricky: a selectable feeding policy, per-call decode
// telemetry, and decision readouts. The closing-bias, whitespace-bias,
// KV-quantisation, and diagnostic-log paths are removed: Bricky passes none
// of them.

import Foundation
import MLX
import MLXGuidedGeneration
import MLXLMCommon

/// Which tokens reach the model after a sampled token commits.
///
/// The pinned upstream loop feeds only the grammar's fast-forward tokens when
/// there are any, so the sampled token that preceded a multi-token forced
/// span (the opening quote of a key, the first letter of an enum value)
/// never enters the KV cache. `legacy` reproduces that exactly, so evidence
/// recorded on device replays byte-for-byte; `feedAll` feeds the sampled
/// token and then every forced token, one pass each. Which one ships is a
/// measured A/B decision (ADR 0010 amendment), not this file's.
public enum DecodeFeeding: String, Codable, CaseIterable, Sendable {
    case legacy
    case feedAll = "feed_all"
}

/// The decoding engine for one call. `upstream` runs the pinned
/// `GuidedGenerationLoop` itself — kept selectable so a pin bump can prove
/// the fork has not drifted (`RecoveryDecoderParityTests`).
public enum DecodeMode: String, Codable, CaseIterable, Sendable {
    case upstream
    case legacy
    case feedAll = "feed_all"

    var feeding: DecodeFeeding? {
        switch self {
        case .upstream: nil
        case .legacy: .legacy
        case .feedAll: .feedAll
        }
    }
}

/// The pure feeding decision, isolated so it is testable without a model.
public enum FeedingPlan {
    public static func tokensToFeed(sampled: Int32, forced: [Int32], policy: DecodeFeeding) -> [Int32] {
        switch policy {
        case .legacy: forced.isEmpty ? [sampled] : forced
        case .feedAll: [sampled] + forced
        }
    }
}

/// What one guided call cost and how its cache was fed. Every count is
/// exact; the timings are wall-clock milliseconds.
public struct DecodeTelemetry: Codable, Sendable, Equatable {
    public var mode: DecodeMode
    /// Prompt length in tokens, image placeholders included.
    public var promptTokens: Int
    /// `<|image_pad|>` tokens in the prompt: what the image cost.
    public var imageTokens: Int?
    /// Image load, resize, and prompt templating before the model runs.
    public var preprocessMilliseconds: Int?
    public var prefillMilliseconds: Int
    public var decodeMilliseconds: Int
    /// Tokens the model chose.
    public var sampledTokens: Int
    /// Tokens the grammar forced (fast-forward).
    public var forcedTokens: Int
    /// Tokens run through the model after prefill, one forward pass each.
    public var fedTokens: Int
    /// Sampled tokens that were emitted but never entered the KV cache.
    public var droppedSampledTokens: Int
    /// The KV cache length when decoding ended.
    public var cacheOffset: Int?
    /// Fast-forward strings the host tokenizer re-encoded differently from
    /// the grammar's own tokens (xgrammar bridge counter).
    public var fastForwardDisagreements: Int

    /// What the cache would hold had every emitted token been fed: the
    /// invariant `feedAll` keeps and `legacy` breaks.
    public var emittedTokens: Int { sampledTokens + forcedTokens }

    enum CodingKeys: String, CodingKey {
        case mode
        case promptTokens = "prompt_tokens"
        case imageTokens = "image_tokens"
        case preprocessMilliseconds = "preprocess_ms"
        case prefillMilliseconds = "prefill_ms"
        case decodeMilliseconds = "decode_ms"
        case sampledTokens = "sampled_tokens"
        case forcedTokens = "forced_tokens"
        case fedTokens = "fed_tokens"
        case droppedSampledTokens = "dropped_sampled_tokens"
        case cacheOffset = "cache_offset"
        case fastForwardDisagreements = "fast_forward_disagreements"
    }
}

/// The model's distribution over the grammar-legal tokens at one decision:
/// masked softmax over the legal set, recorded only where that set is small
/// (an enum value, a slot letter) so traces stay light. Sampling is greedy
/// and unchanged; the readout only records what the argmax chose between.
public struct DecisionReadout: Codable, Sendable, Equatable {
    public struct Candidate: Codable, Sendable, Equatable {
        public let token: Int
        public let text: String
        public let probability: Double
    }

    /// Index of the generated token this decision produced.
    public let position: Int
    public let chosenToken: Int
    /// Legal candidates, most probable first.
    public let candidates: [Candidate]

    enum CodingKeys: String, CodingKey {
        case position
        case chosenToken = "chosen_token"
        case candidates
    }

    /// Softmax over the given logits in double precision.
    public static func normalize(_ logits: [Float]) -> [Double] {
        guard let maximum = logits.max() else { return [] }
        let exponentials = logits.map { exp(Double($0) - Double(maximum)) }
        let total = exponentials.reduce(0, +)
        return exponentials.map { $0 / total }
    }

    /// The token ids a packed LSB-first bitmask allows, or nil when more than
    /// `limit` are legal (a structural position, not a decision worth
    /// recording).
    public static func legalTokens(mask: [Int32], vocabSize: Int, limit: Int) -> [Int]? {
        var ids: [Int] = []
        for (wordIndex, word) in mask.enumerated() {
            var bits = UInt32(bitPattern: word)
            while bits != 0 {
                let id = wordIndex * 32 + bits.trailingZeroBitCount
                bits &= bits - 1
                guard id < vocabSize else { continue }
                ids.append(id)
                if ids.count > limit { return nil }
            }
        }
        return ids
    }
}

/// Grammar-constrained greedy decoding, forked from the pinned
/// `GuidedGenerationLoop.run` so Bricky can choose how the cache is fed and
/// see what each call cost. In `.legacy` it samples, emits, and feeds exactly
/// as upstream does for Bricky's arguments.
enum RecoveryGuidedDecoder {
    struct Result {
        let tokenCount: Int
        /// False when `maxTokens` ran out before the grammar accepted —
        /// upstream's `incompleteOutput`.
        let grammarAccepted: Bool
        let telemetry: DecodeTelemetry
        let readouts: [DecisionReadout]
    }

    /// Legal sets larger than this are structural (whitespace runs, open
    /// strings), not decisions.
    static let readoutLegalLimit = 64

    static func run(
        input: LMInput,
        context: ModelContext,
        constraint: GrammarConstraint,
        maxTokens: Int,
        vocabSize: Int,
        feeding: DecodeFeeding,
        recordReadouts: Bool = true,
        emit: (String) -> Bool
    ) throws -> Result {
        let model = context.model
        let cache = model.newCache(parameters: nil)
        var modelState: LMOutput.State?
        let stopTokenIDs = stopTokens(tokenizer: context.tokenizer, configuration: context.configuration)

        let promptTokens = input.text.tokens.dim(-1)
        let imageTokens = context.tokenizer.convertTokenToId("<|image_pad|>").map { pad in
            input.text.tokens.asType(.int32).asArray(Int32.self).lazy.filter { $0 == Int32(pad) }.count
        }

        let prefillStarted = ContinuousClock.now
        var logits: MLXArray
        switch try model.prepare(input, cache: cache, state: nil, windowSize: 512) {
        case .tokens(let tokens):
            let result = model(tokens[text: .newAxis], cache: cache, state: nil)
            modelState = result.state
            logits = result.logits
        case .logits(let result):
            modelState = result.state
            logits = result.logits
        }
        eval(logits)
        let prefillMilliseconds = milliseconds(since: prefillStarted)
        let decodeStarted = ContinuousClock.now

        var detokenizer = NaiveStreamingDetokenizer(tokenizer: context.tokenizer)
        var tokenCount = 0
        var sampledTokens = 0
        var forcedTokens = 0
        var fedTokens = 0
        var droppedSampledTokens = 0
        var grammarStopped = false
        var readouts: [DecisionReadout] = []

        let logitDim = logits.shape[logits.ndim - 1]
        var mask = try constraint.computeMask()
        var maskArray = buildMaskArray(for: mask, vocabSize: vocabSize, logitDim: logitDim)

        /// One single-token forward pass (T_q = 1), exactly as upstream feeds.
        func feed(_ token: Int32) {
            let tokenInput = LMInput.Text(tokens: MLXArray([token]))
            let result = model(tokenInput[text: .newAxis], cache: cache.isEmpty ? nil : cache, state: modelState)
            modelState = result.state
            logits = result.logits
            fedTokens += 1
        }

        while tokenCount < maxTokens {
            try Task.checkCancellation()
            if mask.isTerminated {
                grammarStopped = true
                break
            }

            let legal = recordReadouts && mask.needsApply
                ? DecisionReadout.legalTokens(mask: mask.mask, vocabSize: vocabSize, limit: readoutLegalLimit)
                : nil
            let token = applyMaskAndSample(logits: logits, maskArray: maskArray)
            let tokenId = Int(token)
            if let legal, legal.count > 1 {
                readouts.append(readout(
                    logits: logits, legal: legal, chosen: tokenId, position: tokenCount, tokenizer: context.tokenizer
                ))
            }

            // EOS is only meaningful where the grammar exposed a real mask;
            // see upstream for why an unconditional splice must not stop.
            if mask.needsApply,
               tokenId == context.tokenizer.unknownTokenId || stopTokenIDs.contains(tokenId) {
                grammarStopped = true
                break
            }

            let commitResult = try constraint.commitToken(Int32(token))
            detokenizer.append(token: tokenId)
            if let text = detokenizer.next(), !emit(text) { break }
            tokenCount += 1
            sampledTokens += 1

            if commitResult.isTerminated {
                grammarStopped = true
                break
            }

            // CommitResult.tokens carries only the jump-forward ids.
            let ffTokens: [Int32] = commitResult.tokens
            if !ffTokens.isEmpty {
                var shouldStopAfterFF = false
                for ffToken in ffTokens {
                    if tokenCount >= maxTokens {
                        shouldStopAfterFF = true
                        break
                    }
                    detokenizer.append(token: Int(ffToken))
                    if let text = detokenizer.next(), !emit(text) {
                        shouldStopAfterFF = true
                        break
                    }
                    tokenCount += 1
                    forcedTokens += 1
                }
                if shouldStopAfterFF { break }

                // Under `.legacy` the sampled token is emitted but never
                // fed: the defect this fork exists to measure.
                if feeding == .legacy {
                    droppedSampledTokens += 1
                }
                for next in FeedingPlan.tokensToFeed(sampled: Int32(token), forced: ffTokens, policy: feeding) {
                    feed(next)
                }
            } else {
                feed(Int32(token))
            }
            asyncEval(logits)
            // Overlap the next mask with the GPU pass, as upstream does.
            mask = try constraint.computeMask()
            maskArray = buildMaskArray(for: mask, vocabSize: vocabSize, logitDim: logitDim)
            eval(logits)
        }

        let telemetry = DecodeTelemetry(
            mode: feeding == .legacy ? .legacy : .feedAll,
            promptTokens: promptTokens,
            imageTokens: imageTokens,
            prefillMilliseconds: prefillMilliseconds,
            decodeMilliseconds: milliseconds(since: decodeStarted),
            sampledTokens: sampledTokens,
            forcedTokens: forcedTokens,
            fedTokens: fedTokens,
            droppedSampledTokens: droppedSampledTokens,
            cacheOffset: cache.first?.offset,
            fastForwardDisagreements: constraint.fastForwardDisagreementCount
        )
        return Result(
            tokenCount: tokenCount,
            grammarAccepted: grammarStopped || tokenCount < maxTokens,
            telemetry: telemetry,
            readouts: readouts
        )
    }

    private static func readout(
        logits: MLXArray,
        legal: [Int],
        chosen: Int,
        position: Int,
        tokenizer: any Tokenizer
    ) -> DecisionReadout {
        let row = logits[0, -1, 0...]
        let values = take(row, MLXArray(legal.map(Int32.init)), axis: 0).asType(.float32).asArray(Float.self)
        let probabilities = DecisionReadout.normalize(values)
        let candidates = zip(legal, probabilities)
            .map { DecisionReadout.Candidate(token: $0, text: tokenizer.decode(tokenIds: [$0]), probability: $1) }
            .sorted { $0.probability > $1.probability }
        return DecisionReadout(position: position, chosenToken: chosen, candidates: candidates)
    }

    // MARK: - Copied from the pinned upstream (internal there)

    static func stopTokens(tokenizer: any Tokenizer, configuration: ModelConfiguration) -> Set<Int> {
        var stopTokenIDs = Set(configuration.eosTokenIds)
        if let eos = tokenizer.eosTokenId {
            stopTokenIDs.insert(eos)
        }
        for token in configuration.extraEOSTokens {
            if let id = tokenizer.convertTokenToId(token) {
                stopTokenIDs.insert(id)
            }
        }
        return stopTokenIDs
    }

    static func applyMaskAndSample(logits rawLogits: MLXArray, maskArray: MLXArray?) -> UInt32 {
        var logits = rawLogits[0..., -1, 0...]
        if let maskArray {
            logits = logits + maskArray
        }
        return argMax(logits, axis: -1).item(UInt32.self)
    }

    static func buildMaskArray(for mask: MaskResult, vocabSize: Int, logitDim: Int) -> MLXArray? {
        guard mask.needsApply else { return nil }
        return mask.mask.withUnsafeBufferPointer { buffer in
            let pointer = UnsafeRawPointer(buffer.baseAddress!).assumingMemoryBound(to: UInt32.self)
            return bitmaskToMLXArray(pointer, maskBitCount: vocabSize, totalCount: logitDim)
        }
    }

    static func bitmaskToMLXArray(_ maskPtr: UnsafePointer<UInt32>, maskBitCount: Int, totalCount: Int) -> MLXArray {
        var floats = [Float](repeating: -Float.infinity, count: totalCount)
        let readCount = min(maskBitCount, totalCount)
        for i in 0 ..< readCount {
            let word = maskPtr[i / 32]
            let bit = (word >> (UInt32(i) % 32)) & 1
            if bit == 1 {
                floats[i] = 0.0
            }
        }
        return MLXArray(floats)
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let components = start.duration(to: .now).components
        return Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
    }
}
