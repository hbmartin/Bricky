import Foundation

/// Full-fidelity record of one guided generation call, produced on success
/// and on structured-output failure alike. Before this existed, a decode
/// failure destroyed the model's raw output and a truncated generation was
/// indistinguishable from a malformed one.
public struct MLXGenerationTrace: Codable, Sendable {
    public enum Termination: String, Codable, Sendable {
        /// The grammar reached an accepting state.
        case accepted
        /// `maxTokens` was exhausted before the grammar accepted; `rawOutput`
        /// holds the truncated prefix.
        case maxTokensExhausted = "max_tokens_exhausted"
        /// The model emitted EOS before the grammar accepted.
        case prematureEOS = "premature_eos"
    }

    public let rawOutput: String
    public let decodeErrorDescription: String?
    /// nil when generation terminated abnormally, because the loop throws
    /// before reporting its count.
    public let generatedTokens: Int?
    public let termination: Termination
    public let latencyMilliseconds: Int
    public let maxTokens: Int
    public let schemaJSON: String

    public init(
        rawOutput: String,
        decodeErrorDescription: String?,
        generatedTokens: Int?,
        termination: Termination,
        latencyMilliseconds: Int,
        maxTokens: Int,
        schemaJSON: String
    ) {
        self.rawOutput = rawOutput
        self.decodeErrorDescription = decodeErrorDescription
        self.generatedTokens = generatedTokens
        self.termination = termination
        self.latencyMilliseconds = latencyMilliseconds
        self.maxTokens = maxTokens
        self.schemaJSON = schemaJSON
    }
}

public struct MLXRankResponse: Sendable {
    /// nil when the emitted text failed to decode against the rank schema.
    public let output: MLXRankOutput?
    public let trace: MLXGenerationTrace
}

public struct MLXCheckResponse: Sendable {
    /// nil when the emitted text failed to decode against the check schema.
    public let output: MLXStepCheckOutput?
    public let trace: MLXGenerationTrace
}
