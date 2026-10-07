#if canImport(FoundationModels)
import Foundation
import FoundationModels

// Requires the iOS 27 / macOS 27 SDKs. With an Xcode 26 SDK `canImport`
// is true but 27-only symbols are missing, so that toolchain is unsupported;
// Xcode 16.4 (CI's harness job) compiles this file out entirely.

/// Repair wording from the on-device system model (ADR 0017). The facts go
/// in the Prompt as a `@Generable` value, never in the Instructions: part
/// labels come from LDraw headers and are untrusted. Output is guided into
/// enum fields plus one sentence, greedy, and held to the facts by
/// `RepairWordingValidator`; anything else falls back to the template.
@available(iOS 27.0, macOS 27.0, *)
public struct FoundationModelsRepairWording: RepairWordingGenerator {
    /// The only trusted text: constant, and never interpolated.
    static let instructions = """
    You rewrite one repair instruction for a person building a brick model. \
    You are given the facts of the repair and a template sentence that is \
    already correct. Write one short, friendly sentence that says exactly \
    what the facts say. Use the part name exactly as given. Mention a \
    direction only if the facts give one, and a number of studs only if the \
    facts give one. Never add a direction, number, colour or part that is \
    not in the facts. Never say how certain anything is. Repeat the facts' \
    action, direction, studs and turn in your answer.
    """

    public let deadline: Duration

    public init(deadline: Duration = .seconds(2)) {
        self.deadline = deadline
    }

    /// Whether wording should be attempted at all: the system model is
    /// ready and speaks the user's language.
    public static func readiness(locale: Locale = .current) -> String? {
        let model = SystemLanguageModel.default
        guard model.isAvailable else { return "model" }
        guard model.supportsLocale(locale) else { return "locale" }
        return nil
    }

    public func word(_ facts: RepairWordingFacts) async -> RepairWordingResult {
        let started = ContinuousClock.now
        func elapsed() -> Int {
            let parts = started.duration(to: .now).components
            return Int(parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000)
        }
        if let reason = Self.readiness() {
            return RepairWordingResult(sentence: nil, outcome: .unavailable(reason), modelSentence: nil, milliseconds: elapsed())
        }
        let promptFacts = GeneratedRepairFacts(facts)
        let deadline = self.deadline
        do {
            let output = try await withThrowingTaskGroup(of: GeneratedRepairWording?.self) { group in
                group.addTask {
                    let session = LanguageModelSession(instructions: Self.instructions)
                    let response = try await session.respond(
                        generating: GeneratedRepairWording.self,
                        options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 120)
                    ) {
                        "Facts of the repair:"
                        promptFacts
                    }
                    return response.content
                }
                group.addTask {
                    try await Task.sleep(for: deadline)
                    return nil
                }
                let first = try await group.next() ?? nil
                group.cancelAll()
                return first
            }
            guard let output else {
                return RepairWordingResult(sentence: nil, outcome: .failed("timeout"), modelSentence: nil, milliseconds: elapsed())
            }
            let candidate = output.wordingOutput
            if let rejection = RepairWordingValidator.validate(candidate, facts: facts) {
                return RepairWordingResult(
                    sentence: nil, outcome: .rejected(rejection), modelSentence: candidate.sentence, milliseconds: elapsed()
                )
            }
            return RepairWordingResult(
                sentence: candidate.sentence.trimmingCharacters(in: .whitespacesAndNewlines),
                outcome: .accepted, modelSentence: candidate.sentence, milliseconds: elapsed()
            )
        } catch {
            return RepairWordingResult(sentence: nil, outcome: .failed(Self.reason(error)), modelSentence: nil, milliseconds: elapsed())
        }
    }

    /// A short, stable name for why generation failed.
    static func reason(_ error: Error) -> String {
        if let error = error as? LanguageModelError {
            switch error {
            case .refusal: return "refusal"
            case .guardrailViolation: return "guardrail"
            case .timeout: return "timeout"
            case .unsupportedLanguageOrLocale: return "locale"
            case .contextSizeExceeded: return "context"
            case .rateLimited: return "rate_limited"
            default: return "model_error"
            }
        }
        if error is CancellationError { return "cancelled" }
        return "error"
    }
}

// MARK: - Guided types

@available(iOS 27.0, macOS 27.0, *)
@Generable
enum GeneratedAction {
    case add, move, rotate, swapColour, remove, reAdd
}

@available(iOS 27.0, macOS 27.0, *)
@Generable
enum GeneratedDirection {
    case awayFromYou, towardYou, yourLeft, yourRight, screenUp, screenDown, screenLeft, screenRight
}

@available(iOS 27.0, macOS 27.0, *)
@Generable
enum GeneratedTurn {
    case quarter, half
}

/// The facts as the model reads them, in the Prompt.
@available(iOS 27.0, macOS 27.0, *)
@Generable
struct GeneratedRepairFacts {
    var action: GeneratedAction
    @Guide(description: "The part's name. Use it exactly.")
    var partName: String
    var direction: GeneratedDirection?
    var studs: Int?
    var turn: GeneratedTurn?
    @Guide(description: "A correct sentence to rephrase.")
    var template: String
}

/// What the model writes back.
@available(iOS 27.0, macOS 27.0, *)
@Generable
struct GeneratedRepairWording {
    @Guide(description: "The action from the facts.")
    var action: GeneratedAction
    @Guide(description: "The direction from the facts, or nil when the facts give none.")
    var direction: GeneratedDirection?
    @Guide(description: "The number of studs from the facts, or nil when the facts give none.")
    var studs: Int?
    @Guide(description: "The turn from the facts, or nil when the facts give none.")
    var turn: GeneratedTurn?
    @Guide(description: "One short sentence for the person building.")
    var sentence: String
}

@available(iOS 27.0, macOS 27.0, *)
extension GeneratedRepairFacts {
    init(_ facts: RepairWordingFacts) {
        self.init(
            action: GeneratedAction(facts.action), partName: facts.partLabel,
            direction: facts.direction.map(GeneratedDirection.init), studs: facts.studs,
            turn: facts.turn.map(GeneratedTurn.init), template: facts.template
        )
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension GeneratedRepairWording {
    var wordingOutput: RepairWordingOutput {
        RepairWordingOutput(
            action: action.wording, direction: direction?.wording, studs: studs, turn: turn?.wording, sentence: sentence
        )
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension GeneratedAction {
    init(_ action: RepairWordingAction) {
        switch action {
        case .add: self = .add
        case .move: self = .move
        case .rotate: self = .rotate
        case .swapColour: self = .swapColour
        case .remove: self = .remove
        case .reAdd: self = .reAdd
        }
    }

    var wording: RepairWordingAction {
        switch self {
        case .add: .add
        case .move: .move
        case .rotate: .rotate
        case .swapColour: .swapColour
        case .remove: .remove
        case .reAdd: .reAdd
        }
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension GeneratedDirection {
    init(_ direction: RepairWordingDirection) {
        switch direction {
        case .awayFromYou: self = .awayFromYou
        case .towardYou: self = .towardYou
        case .yourLeft: self = .yourLeft
        case .yourRight: self = .yourRight
        case .screenUp: self = .screenUp
        case .screenDown: self = .screenDown
        case .screenLeft: self = .screenLeft
        case .screenRight: self = .screenRight
        }
    }

    var wording: RepairWordingDirection {
        switch self {
        case .awayFromYou: .awayFromYou
        case .towardYou: .towardYou
        case .yourLeft: .yourLeft
        case .yourRight: .yourRight
        case .screenUp: .screenUp
        case .screenDown: .screenDown
        case .screenLeft: .screenLeft
        case .screenRight: .screenRight
        }
    }
}

@available(iOS 27.0, macOS 27.0, *)
extension GeneratedTurn {
    init(_ turn: RepairWordingTurn) {
        self = turn == .half ? .half : .quarter
    }

    var wording: RepairWordingTurn { self == .half ? .half : .quarter }
}
#endif
