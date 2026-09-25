import Foundation
// Decode telemetry, readouts, and variants live in the evidence kit so rows
// can carry them without MLX; RecoveryMLX clients get them through here.
@_exported import RecoveryEvidenceKit

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
        /// Declared for old traces only: the pinned loop never throws its
        /// `prematureEOS` (an EOS the grammar allows is acceptance), so no
        /// call produces this.
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
    /// Decode telemetry (nil for the `upstream` engine, which exposes
    /// none) plus memory and thermal state around the call.
    public let inference: InferenceTelemetry?
    /// The model's distribution at each small-legal-set decision.
    public let readouts: [DecisionReadout]?

    public var telemetry: DecodeTelemetry? { inference?.decode }

    public init(
        rawOutput: String,
        decodeErrorDescription: String?,
        generatedTokens: Int?,
        termination: Termination,
        latencyMilliseconds: Int,
        maxTokens: Int,
        schemaJSON: String,
        inference: InferenceTelemetry? = nil,
        readouts: [DecisionReadout]? = nil
    ) {
        self.rawOutput = rawOutput
        self.decodeErrorDescription = decodeErrorDescription
        self.generatedTokens = generatedTokens
        self.termination = termination
        self.latencyMilliseconds = latencyMilliseconds
        self.maxTokens = maxTokens
        self.schemaJSON = schemaJSON
        self.inference = inference
        self.readouts = readouts
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
