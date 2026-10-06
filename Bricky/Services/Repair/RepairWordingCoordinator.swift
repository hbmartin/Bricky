import BrickyLanguage
import Foundation

/// Words the repair on screen (ADR 0017): the String Catalog template at
/// once, then the language layer's sentence if one arrives for the same
/// facts and passes `RepairWordingValidator`. A sentence for facts that are
/// no longer current is dropped. Without a generator it is the template,
/// exactly as before.
@MainActor
final class RepairWordingCoordinator {
    /// Facts worded per AR guide visit, so a verdict that flickers between
    /// two repairs does not re-ask the model.
    static let cacheLimit = 32

    private let generator: (any RepairWordingGenerator)?
    private var cache: [RepairWordingFacts: RepairWordingResult] = [:]
    private var current: RepairWordingFacts?
    private var task: Task<Void, Never>?
    /// The line to show for the current facts.
    private(set) var sentence: String?
    /// Called on the main actor when a validated sentence replaces the
    /// template for the facts still on screen.
    var onWorded: ((String) -> Void)?
    /// Every finished attempt, accepted or not, for evidence.
    var onResult: ((RepairWordingFacts, RepairWordingResult) -> Void)?

    init(generator: (any RepairWordingGenerator)?) {
        self.generator = generator
    }

    /// The line to show now for `facts`: a cached sentence, else the
    /// template while the model is asked in the background.
    @discardableResult
    func update(_ facts: RepairWordingFacts?) -> String? {
        guard let facts else {
            cancel()
            current = nil
            sentence = nil
            return nil
        }
        if facts == current { return sentence }
        cancel()
        current = facts
        if let cached = cache[facts] {
            sentence = cached.sentence ?? facts.template
            return sentence
        }
        sentence = facts.template
        guard let generator else { return sentence }
        task = Task { [weak self] in
            let result = await generator.word(facts)
            guard !Task.isCancelled else { return }
            self?.finish(facts, result)
        }
        return sentence
    }

    private func finish(_ facts: RepairWordingFacts, _ result: RepairWordingResult) {
        if cache.count >= Self.cacheLimit { cache.removeAll() }
        cache[facts] = result
        onResult?(facts, result)
        guard facts == current, let worded = result.sentence else { return }
        sentence = worded
        onWorded?(worded)
    }

    /// Forgets everything, e.g. when the guide follows another step.
    func reset() {
        cancel()
        cache.removeAll()
        current = nil
        sentence = nil
    }

    private func cancel() {
        task?.cancel()
        task = nil
    }
}
