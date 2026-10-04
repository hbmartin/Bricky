import Foundation
import MLX
import MLXGuidedGeneration
import MLXLMCommon

/// Probe scoring: instead of generating the answer, force a canonical answer
/// prefix and read the model's masked distribution where the decision is
/// made — the status value and the first ranking slot for a rank, the verdict
/// for a check — all from one prefill. Qwen3-VL's `prepare` returns logits
/// for every prompt position, so no decode pass is needed.
///
/// The prefix follows the model's own formatting (`{ "status": "matched",
/// "ranking": ["`, spaced as it generates), and is committed to a matcher
/// compiled without fast-forward, whose mask at each prefix position is the
/// legal set the readout normalizes over.
enum RecoveryProbe {
    enum ProbeError: LocalizedError {
        case prefixRejected(String)
        case boundaryNotFound(String)

        var errorDescription: String? {
            switch self {
            case .prefixRejected(let prefix): "The grammar rejected the probe prefix \(prefix)."
            case .boundaryNotFound(let marker): "The probe prefix has no token boundary after \(marker)."
            }
        }
    }

    struct Decision {
        let prefix: String
        /// The prefix up to where the status value starts, when there is one.
        let statusMarker: String?
        let options: [String]

        static func rank(slotCount: Int, letters: [String]) -> Decision {
            Decision(
                prefix: #"{ "status": "matched", "ranking": [""#,
                statusMarker: #"{ "status": ""#,
                options: Array(letters.prefix(min(max(slotCount, 1), letters.count)))
            )
        }

        static let check = Decision(
            prefix: #"{ "result": ""#,
            statusMarker: nil,
            options: ["complete", "incomplete", "uncertain"]
        )
    }

    struct Result {
        let readout: ProbeReadout
        let readouts: [DecisionReadout]
        let telemetry: DecodeTelemetry
        let rawOutput: String
    }

    /// Legal sets larger than this are not a decision.
    static let legalLimit = 256

    static func run(
        input: LMInput,
        context: ModelContext,
        constraint: GrammarConstraint,
        vocabSize: Int,
        decision: Decision
    ) throws -> Result {
        let tokenizer = context.tokenizer
        let prefixTokens = tokenizer.encode(text: decision.prefix, addSpecialTokens: false)
        var masks: [MaskResult] = []
        for token in prefixTokens {
            masks.append(try constraint.computeMask())
            do {
                _ = try constraint.commitToken(Int32(token))
            } catch {
                throw ProbeError.prefixRejected(decision.prefix)
            }
        }
        let finalMask = try constraint.computeMask()

        // The status value is predicted at the last position before it.
        var statusIndex: Int?
        if let marker = decision.statusMarker {
            statusIndex = (1...prefixTokens.count).first {
                tokenizer.decode(tokenIds: Array(prefixTokens[..<$0])) == marker
            }
            guard statusIndex != nil else { throw ProbeError.boundaryNotFound(marker) }
        }

        let prompt = input.text.tokens
        let promptLength = prompt.dim(-1)
        let prefixArray = MLXArray(prefixTokens.map(Int32.init)).reshaped([1, prefixTokens.count]).asType(prompt.dtype)
        let mask = input.text.mask.map {
            concatenated([$0, MLXArray.ones([1, prefixTokens.count], dtype: $0.dtype)], axis: -1)
        }
        let full = LMInput(
            text: .init(tokens: concatenated([prompt, prefixArray], axis: -1), mask: mask),
            image: input.image
        )
        let cache = context.model.newCache(parameters: nil)
        let started = ContinuousClock.now
        let logits: MLXArray
        switch try context.model.prepare(full, cache: cache, state: nil, windowSize: nil) {
        case .tokens(let tokens):
            logits = context.model(tokens[text: .newAxis], cache: cache, state: nil).logits
        case .logits(let result):
            logits = result.logits
        }
        eval(logits)
        let prefillMilliseconds = milliseconds(since: started)
        let totalLength = promptLength + prefixTokens.count
        // Logits cover every position with this pin; a future pin that
        // returns only the last position still yields the final decision.
        let coversAllPositions = logits.dim(1) == totalLength

        func distribution(at position: Int, mask: MaskResult) -> (ids: [Int], probabilities: [Double])? {
            let row = coversAllPositions ? position : logits.dim(1) - 1
            guard coversAllPositions || position == totalLength - 1,
                  let legal = DecisionReadout.legalTokens(mask: mask.mask, vocabSize: vocabSize, limit: legalLimit),
                  !legal.isEmpty else { return nil }
            let values = take(logits[0, row, 0...], MLXArray(legal.map(Int32.init)), axis: 0)
                .asType(.float32).asArray(Float.self)
            return (legal, DecisionReadout.normalize(values))
        }

        func candidates(_ ids: [Int], _ probabilities: [Double]) -> [DecisionReadout.Candidate] {
            zip(ids, probabilities)
                .map { DecisionReadout.Candidate(token: $0, text: tokenizer.decode(tokenIds: [$0]), probability: $1) }
                .sorted { $0.probability > $1.probability }
        }

        var readouts: [DecisionReadout] = []
        var pInsufficient: Double?
        if let statusIndex, let status = distribution(at: promptLength + statusIndex - 1, mask: masks[statusIndex]) {
            let scored = candidates(status.ids, status.probabilities)
            readouts.append(DecisionReadout(position: statusIndex, chosenToken: scored.first?.token ?? -1, candidates: scored))
            pInsufficient = ProbeScoring.group(
                scored.map { ($0.text, $0.probability) }, options: ["matched", "insufficient"]
            )["insufficient"]
        }
        var options: [String: Double] = [:]
        if let final = distribution(at: totalLength - 1, mask: finalMask) {
            let scored = candidates(final.ids, final.probabilities)
            readouts.append(DecisionReadout(position: prefixTokens.count, chosenToken: scored.first?.token ?? -1, candidates: scored))
            options = ProbeScoring.group(scored.map { ($0.text, $0.probability) }, options: decision.options)
        }
        let readout = ProbeReadout(pInsufficient: pInsufficient, options: options)

        let rawOutput: String
        if decision.statusMarker != nil {
            let status = (pInsufficient ?? 0) > ProbeScoring.insufficientThreshold ? "insufficient" : "matched"
            let ranking = readout.ranked.map { "\"\($0)\"" }.joined(separator: ",")
            rawOutput = #"{"status":"\#(status)","ranking":[\#(ranking)]}"#
        } else {
            rawOutput = #"{"result":"\#(readout.ranked.first ?? "uncertain")"}"#
        }

        let imageTokens = tokenizer.convertTokenToId("<|image_pad|>").map { pad in
            prompt.asType(.int32).asArray(Int32.self).lazy.filter { $0 == Int32(pad) }.count
        }
        let telemetry = DecodeTelemetry(
            mode: .legacy,
            promptTokens: totalLength,
            imageTokens: imageTokens,
            prefillMilliseconds: prefillMilliseconds,
            decodeMilliseconds: 0,
            sampledTokens: 0,
            forcedTokens: prefixTokens.count,
            fedTokens: 0,
            droppedSampledTokens: 0,
            cacheOffset: cache.first?.offset,
            fastForwardDisagreements: 0
        )
        return Result(readout: readout, readouts: readouts, telemetry: telemetry, rawOutput: rawOutput)
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let components = start.duration(to: .now).components
        return Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
    }
}
