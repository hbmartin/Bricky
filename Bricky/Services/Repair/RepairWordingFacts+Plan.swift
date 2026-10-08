import BrickyLanguage
import Foundation

extension RepairWordingFacts {
    /// The facts of the sentence `RepairPhrasebook` would say for `actions`:
    /// the same subject, and a direction only where the template uses one
    /// (a one-stud move with a steady direction).
    init?(actions: [RepairAction], direction: RelativeDirection?, labels: [Int: String], template: String) {
        guard let first = actions.first, let action = RepairWordingAction(rawValue: first.name) else { return nil }
        var studs: Int?
        var turn: RepairWordingTurn?
        var wordedDirection: RepairWordingDirection?
        switch first {
        case .move(_, let by):
            let steps = abs(by.dx) + abs(by.dz)
            studs = steps
            if steps == 1, let direction { wordedDirection = RepairWordingDirection(rawValue: direction.rawValue) }
        case .rotate(_, let quarterTurns):
            turn = quarterTurns % 4 == 2 ? .half : .quarter
        default:
            break
        }
        self.init(
            action: action,
            partLabel: RepairPhrasebook.subject(for: actions, labels: labels),
            partCount: actions.count,
            direction: wordedDirection,
            studs: studs,
            turn: turn,
            template: template
        )
    }
}

enum RepairWordingSource {
    /// The language layer when the developer setting is on, the build can
    /// import FoundationModels, and the app speaks English (the String
    /// Catalog is English only, and a model sentence must match the rest of
    /// the screen). Otherwise nil: the templates, exactly as before. Whether
    /// the system model is ready is checked each time it phrases, and a
    /// model that is not falls back to the template.
    @MainActor
    static func generator(enabled: Bool, preferredLocalizations: [String] = Bundle.main.preferredLocalizations) -> (any RepairWordingGenerator)? {
        guard enabled, preferredLocalizations.first?.hasPrefix("en") == true else { return nil }
        #if canImport(FoundationModels)
        return FoundationModelsRepairWording()
        #else
        return nil
        #endif
    }
}
