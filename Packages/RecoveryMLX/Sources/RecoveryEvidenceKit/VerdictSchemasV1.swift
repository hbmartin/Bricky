import Foundation

/// The one declaration of what a step check may answer. The MLX grammar,
/// the cloud-assist schema, the app's `StepCheckResult` and the scorer's
/// `CHECK_VERDICTS` all mirror it, and tests hold each mirror to it.
public enum CheckVerdictV1: String, Codable, Sendable, CaseIterable {
    case complete
    case incomplete
    case uncertain
}

public enum VerdictSchemasV1 {
    /// The check grammar exactly as the MLX runtime compiles it. These bytes
    /// are the grammar cache key and the `schema_json` of every check trace,
    /// so they are pinned: re-serializing would change recorded evidence.
    public static let checkGrammarJSON = #"{"type":"object","properties":{"result":{"type":"string","enum":["complete","incomplete","uncertain"]}},"required":["result"],"additionalProperties":false}"#

    /// The verdict values in schema order, for schemas built as dictionaries
    /// (cloud assist) rather than as pinned bytes.
    public static var checkVerdictValues: [String] {
        CheckVerdictV1.allCases.map(\.rawValue)
    }
}
