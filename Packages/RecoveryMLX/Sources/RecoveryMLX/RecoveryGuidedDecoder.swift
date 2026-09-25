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

/// The unique-slots variant, as a pure decision: which legal tokens would
/// repeat a slot letter already in the ranking. Letters are uppercase A–H,
/// which appear nowhere else in the rank grammar (keys and enum values are
/// lowercase), so a legal token carrying one is a slot choice.
public enum SlotUniqueness {
    public static func slotLetters(in text: String, allowed: Set<Character>) -> Set<Character> {
        Set(text.filter { allowed.contains($0) })
    }

    /// Legal tokens to mask because their text names an already-emitted
    /// letter. The grammar's `maxItems` equals the slot count, so once every
    /// letter is used it requires `]`: a legal letter always remains while
    /// one is needed.
    public static func blockedTokens(legal: [Int], text: (Int) -> String, emitted: Set<Character>, allowed: Set<Character>) -> [Int] {
        guard !emitted.isEmpty else { return [] }
        return legal.filter { !slotLetters(in: text($0), allowed: allowed).isDisjoint(with: emitted) }
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
        uniqueSlotLetters: Set<Character>? = nil,
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
        var emittedSlots: Set<Character> = []
        var maskedRepeatSlots = 0
        var cacheHeldEveryEmittedToken = true

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

            // The invariant feed_all exists to keep: everything emitted so far
            // is in the cache the model conditions on.
            if cache.first?.offset != promptTokens + sampledTokens + forcedTokens {
                cacheHeldEveryEmittedToken = false
                assert(feeding != .feedAll, "feed_all left an emitted token out of the KV cache")
            }
            let legal = (recordReadouts || uniqueSlotLetters != nil) && mask.needsApply
                ? DecisionReadout.legalTokens(mask: mask.mask, vocabSize: vocabSize, limit: readoutLegalLimit)
                : nil
            var sampleMask = maskArray
            if let allowed = uniqueSlotLetters, let legal {
                let blocked = SlotUniqueness.blockedTokens(
                    legal: legal, text: { context.tokenizer.decode(tokenIds: [$0]) }, emitted: emittedSlots, allowed: allowed
                )
                if !blocked.isEmpty, let base = maskArray {
                    var penalty = [Float](repeating: 0, count: logitDim)
                    for id in blocked where id < logitDim { penalty[id] = -Float.infinity }
                    sampleMask = base + MLXArray(penalty)
                    maskedRepeatSlots += blocked.count
                }
            }
            let token = applyMaskAndSample(logits: logits, maskArray: sampleMask)
            let tokenId = Int(token)
            if let allowed = uniqueSlotLetters {
                emittedSlots.formUnion(SlotUniqueness.slotLetters(in: context.tokenizer.decode(tokenIds: [tokenId]), allowed: allowed))
            }
            if recordReadouts, let legal, legal.count > 1 {
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
            fastForwardDisagreements: constraint.fastForwardDisagreementCount,
            cacheHeldEveryEmittedToken: cacheHeldEveryEmittedToken,
            maskedRepeatSlots: uniqueSlotLetters == nil ? nil : maskedRepeatSlots
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
