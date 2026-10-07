import Foundation

// The language layer's repair wording (Phase 3 M3.3, ADR 0017): a model may
// phrase a repair, never decide one. Everything here is Foundation-only, so
// it compiles and is tested on every toolchain; the Foundation Models
// generator beside it compiles only where the framework exists.

/// What a repair asks the user to do. Mirrors the app's `RepairAction` names.
public enum RepairWordingAction: String, Sendable, Hashable, CaseIterable, Codable {
    case add
    case move
    case rotate
    case swapColour = "swap_colour"
    case remove
    case reAdd = "re_add"
}

/// Which way, from where the user stands. Mirrors the app's
/// `RelativeDirection` raw values; measured from poses, never by a model.
public enum RepairWordingDirection: String, Sendable, Hashable, CaseIterable, Codable {
    case awayFromYou = "away_from_you"
    case towardYou = "toward_you"
    case yourLeft = "your_left"
    case yourRight = "your_right"
    case screenUp = "screen_up"
    case screenDown = "screen_down"
    case screenLeft = "screen_left"
    case screenRight = "screen_right"
}

public enum RepairWordingTurn: String, Sendable, Hashable, CaseIterable, Codable {
    case quarter
    case half
}

/// The deterministic facts of one repair: everything the sentence may say.
/// Built from the repair plan, the stabilised direction and the part label;
/// the template sentence is the fallback that is always available.
public struct RepairWordingFacts: Sendable, Hashable, Codable {
    public let action: RepairWordingAction
    /// What to call the part: "red Brick 2 x 4", or "parts from this step".
    /// Comes from LDraw file headers, so it is untrusted text, sanitised.
    public let partLabel: String
    public let partCount: Int
    public let direction: RepairWordingDirection?
    /// Lattice steps for a move.
    public let studs: Int?
    public let turn: RepairWordingTurn?
    /// The String Catalog sentence (`RepairPhrasebook`).
    public let template: String

    public init(
        action: RepairWordingAction, partLabel: String, partCount: Int = 1, direction: RepairWordingDirection? = nil,
        studs: Int? = nil, turn: RepairWordingTurn? = nil, template: String
    ) {
        self.action = action
        self.partLabel = RepairLabelSanitizer.sanitize(partLabel)
        self.partCount = partCount
        self.direction = direction
        self.studs = studs
        self.turn = turn
        self.template = template
    }

    enum CodingKeys: String, CodingKey {
        case action, direction, studs, turn, template
        case partLabel = "part_label"
        case partCount = "part_count"
    }
}

/// What a generator says it wrote: the facts it used, and the sentence.
public struct RepairWordingOutput: Sendable, Hashable, Codable {
    public let action: RepairWordingAction
    public let direction: RepairWordingDirection?
    public let studs: Int?
    public let turn: RepairWordingTurn?
    public let sentence: String

    public init(
        action: RepairWordingAction, direction: RepairWordingDirection?, studs: Int?, turn: RepairWordingTurn?,
        sentence: String
    ) {
        self.action = action
        self.direction = direction
        self.studs = studs
        self.turn = turn
        self.sentence = sentence
    }
}

/// Untrusted part text, made safe to show and to put in a prompt: control
/// characters stripped, whitespace collapsed, length capped.
public enum RepairLabelSanitizer {
    public static let maximumLength = 80

    public static func sanitize(_ text: String, maximumLength: Int = maximumLength) -> String {
        let scalars = text.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) ? " " : Character(scalar)
        }
        let collapsed = String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(collapsed.prefix(maximumLength))
    }
}

/// Holds a generated sentence to the facts. Any rejection means the
/// template is shown instead: the model may phrase, never add.
public enum RepairWordingValidator {
    public enum Rejection: String, Sendable, Hashable, Codable {
        case actionMismatch = "action_mismatch"
        case directionMismatch = "direction_mismatch"
        case studsMismatch = "studs_mismatch"
        case turnMismatch = "turn_mismatch"
        case empty
        case tooLong = "too_long"
        case notOneSentence = "not_one_sentence"
        case missingLabel = "missing_label"
        /// A direction the facts do not hold, or any rotation sense.
        case foreignDirection = "foreign_direction"
        /// A number other than the stud count.
        case foreignNumber = "foreign_number"
        /// A colour word that is not in the part's own label.
        case foreignColour = "foreign_colour"
        case forbiddenWord = "forbidden_word"
    }

    /// CONTRIBUTING and ADR 0015: never claimed, never "about one stud".
    public static let forbiddenWords = ["automatic", "detected", "found", "locked on", "about one stud"]
    public static let maximumLength = 160

    static let directionWords: Set<String> = [
        "left", "right", "toward", "towards", "away", "up", "down", "top", "bottom", "forward", "forwards",
        "backward", "backwards", "front", "behind", "clockwise", "counterclockwise", "anticlockwise",
        "north", "south", "east", "west"
    ]

    static func allowedDirectionWords(_ direction: RepairWordingDirection?) -> Set<String> {
        switch direction {
        case nil: []
        case .awayFromYou: ["away"]
        case .towardYou: ["toward", "towards"]
        case .yourLeft, .screenLeft: ["left"]
        case .yourRight, .screenRight: ["right"]
        case .screenUp: ["toward", "towards", "top", "up"]
        case .screenDown: ["toward", "towards", "bottom", "down"]
        }
    }

    static let numberWords = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10]
    /// A spelled-out number counts only before one of these ("one stud",
    /// "two times"); "a blue one" is a pronoun, not a quantity.
    static let quantityNouns: Set<String> = [
        "stud", "studs", "plate", "plates", "time", "times", "turn", "turns", "step", "steps", "part", "parts",
        "brick", "bricks", "more", "row", "rows"
    ]

    static let colourWords: Set<String> = [
        "red", "blue", "yellow", "green", "black", "white", "grey", "gray", "orange", "brown", "tan", "pink",
        "purple", "lime", "azure", "magenta", "violet", "silver", "gold", "beige", "olive", "teal", "cyan",
        "maroon", "navy", "coral", "lavender", "turquoise", "transparent", "clear"
    ]

    /// Nil when `output` may be shown for `facts`.
    public static func validate(_ output: RepairWordingOutput, facts: RepairWordingFacts) -> Rejection? {
        guard output.action == facts.action else { return .actionMismatch }
        guard output.direction == facts.direction else { return .directionMismatch }
        guard output.studs == facts.studs else { return .studsMismatch }
        guard output.turn == facts.turn else { return .turnMismatch }
        let sentence = output.sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sentence.isEmpty else { return .empty }
        guard sentence.count <= maximumLength else { return .tooLong }
        let lowered = sentence.lowercased()
        let label = facts.partLabel.lowercased()
        guard !label.isEmpty, let labelRange = lowered.range(of: label) else { return .missingLabel }
        // Judge the sentence without the label: part names may carry
        // numbers, sides ("Wedge 3 x 2 Left") and colours of their own.
        let rest = lowered.replacingCharacters(in: labelRange, with: " ")
        guard rest.hasSuffix("."), rest.dropLast().allSatisfy({ !".!?\n".contains($0) }) else { return .notOneSentence }
        if forbiddenWords.contains(where: lowered.contains) { return .forbiddenWord }
        let words = rest.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let allowed = allowedDirectionWords(facts.direction)
        if words.contains(where: { directionWords.contains($0) && !allowed.contains($0) }) { return .foreignDirection }
        for (index, word) in words.enumerated() {
            let next = index + 1 < words.count ? words[index + 1] : ""
            let number = Int(word) ?? (quantityNouns.contains(next) ? numberWords[word] : nil)
            if let number, number != facts.studs { return .foreignNumber }
        }
        let labelWords = Set(label.split { !$0.isLetter }.map(String.init))
        if words.contains(where: { colourWords.contains($0) && !labelWords.contains($0) }) { return .foreignColour }
        return nil
    }
}

/// How one wording attempt ended, for evidence and evaluation.
public enum RepairWordingOutcome: Sendable, Hashable, Codable {
    case accepted
    case rejected(RepairWordingValidator.Rejection)
    /// The system model is unavailable, or the locale unsupported.
    case unavailable(String)
    /// A refusal, guardrail, timeout or other error.
    case failed(String)

    public var name: String {
        switch self {
        case .accepted: "accepted"
        case .rejected(let rejection): "rejected_\(rejection.rawValue)"
        case .unavailable(let reason): "unavailable_\(reason)"
        case .failed(let reason): "failed_\(reason)"
        }
    }
}

public struct RepairWordingResult: Sendable, Hashable {
    /// The sentence to show: the model's when accepted, else nil and the
    /// caller shows the template.
    public let sentence: String?
    public let outcome: RepairWordingOutcome
    /// What the model wrote, accepted or not, for evidence.
    public let modelSentence: String?
    public let milliseconds: Int

    public init(sentence: String?, outcome: RepairWordingOutcome, modelSentence: String?, milliseconds: Int) {
        self.sentence = sentence
        self.outcome = outcome
        self.modelSentence = modelSentence
        self.milliseconds = milliseconds
    }
}

/// Phrases a repair from its facts. Implementations never throw: any
/// failure is an outcome, and the caller keeps the template.
public protocol RepairWordingGenerator: Sendable {
    func word(_ facts: RepairWordingFacts) async -> RepairWordingResult
}
