import Foundation

/// The words for a repair (M2.4, ADR 0015). Fixed templates from the String
/// Catalog, one full sentence per action and direction so translations never
/// stitch fragments together. The plan decides what to do; the phrasebook
/// only says it. Never "automatic", "detected", "found" or "locked on"
/// (CONTRIBUTING).
enum RepairPhrasebook {
    /// What to call the part in a sentence: one part's name, or the step's
    /// parts together when the plan moves several.
    static func subject(for actions: [RepairAction], labels: [Int: String]) -> String {
        guard actions.count == 1, let action = actions.first else {
            return String(localized: "parts from this step")
        }
        return labels[action.target.placement] ?? String(localized: "part")
    }

    /// The sentence for `actions`, which a plan derived together (they share
    /// a kind and an offset). Nil when there is nothing to say.
    static func sentence(for actions: [RepairAction], direction: RelativeDirection?, labels: [Int: String]) -> String? {
        guard let first = actions.first else { return nil }
        let part = subject(for: actions, labels: labels)
        switch first {
        case .add:
            return String(localized: "Add the \(part).")
        case .move(_, let by):
            guard abs(by.dx) + abs(by.dz) == 1, let direction else {
                return String(localized: "Move the \(part) back to where the guide shows it.")
            }
            return move(part: part, direction: direction)
        case .rotate(_, let turns):
            return turns % 4 == 2
                ? String(localized: "Turn the \(part) around.")
                : String(localized: "Turn the \(part) a quarter turn.")
        case .swapColour:
            return String(localized: "Swap the \(part) for the colour the guide shows.")
        case .remove:
            return String(localized: "Take off the \(part).")
        case .reAdd:
            return String(localized: "Put the \(part) back.")
        }
    }

    private static func move(part: String, direction: RelativeDirection) -> String {
        switch direction {
        case .awayFromYou: String(localized: "Move the \(part) one stud away from you.")
        case .towardYou: String(localized: "Move the \(part) one stud toward you.")
        case .yourLeft: String(localized: "Move the \(part) one stud to your left.")
        case .yourRight: String(localized: "Move the \(part) one stud to your right.")
        case .screenUp: String(localized: "Move the \(part) one stud toward the top of the screen.")
        case .screenDown: String(localized: "Move the \(part) one stud toward the bottom of the screen.")
        case .screenLeft: String(localized: "Move the \(part) one stud to the left on screen.")
        case .screenRight: String(localized: "Move the \(part) one stud to the right on screen.")
        }
    }
}
