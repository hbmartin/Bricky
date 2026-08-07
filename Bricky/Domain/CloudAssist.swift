import Foundation

/// The advisory second opinion returned by a cloud vision provider
/// (ADR 0011). The verdict is constrained to the same enum the local
/// grammars produce, so cloud and local opinions decode into identical
/// domain types and flow through the same advisory UI.
struct CloudAssistOpinion: Codable, Hashable, Sendable {
    var verdict: StepCheckResult
    var rationale: String
}

/// The minimal step context sent alongside the consented frame. Nothing
/// here identifies the authored model beyond a step position; instruction
/// models and LDraw files never leave the device (ADR 0011).
struct CloudAssistContext: Hashable, Sendable {
    var stepIndex: Int
    var stepCount: Int
}

enum CloudAssistError: LocalizedError, Equatable {
    /// No API key is stored; the caller should route the user to Storage.
    case missingKey
    /// The provider's safety classifiers declined the request (a normal
    /// HTTP 200 with `stop_reason: "refusal"`, not a transport failure).
    case refused
    /// The HTTP body was not a message in the shape this client expects.
    case invalidResponse(String)
    /// The API returned an error envelope (auth, rate limit, overload…).
    case api(String)

    var errorDescription: String? {
        switch self {
        case .missingKey:
            "Add your Anthropic API key in Storage to use cloud assist."
        case .refused:
            "The cloud model declined to evaluate this image."
        case .invalidResponse(let detail):
            "Unexpected cloud response: \(detail)"
        case .api(let message):
            message
        }
    }
}
