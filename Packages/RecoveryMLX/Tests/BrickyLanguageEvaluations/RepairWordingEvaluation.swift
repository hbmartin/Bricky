#if canImport(Evaluations) && canImport(FoundationModels)
import BrickyLanguage
import Evaluations
import Foundation
import Testing

// The language layer's Evaluations suite (ADR 0017): every template the
// phrasebook says, through the system model, scored by code checks. Local
// only, and only with BRICKY_FM_LIVE=1 on a macOS 27 Mac with Apple
// Intelligence on; a Mac is not the phone's model tier, so these numbers
// guide prompt work and never decide the default. A model judge would need
// hand ratings with kappa > 0.6 first (roadmap §4.6), so there is none.

/// What one wording attempt produced, as the framework records it.
struct WordingValue: Codable, Sendable, Equatable {
    var sentence: String?
    var outcome: String
    var milliseconds: Int
}

@available(macOS 27.0, iOS 27.0, *)
struct RepairWordingEvaluation: Evaluation {
    /// One instance for the run, so the test body reads the same metrics.
    static let shared = RepairWordingEvaluation()

    func subject(from sample: ModelSample<WordingValue>) async throws -> ModelSubject<WordingValue> {
        let facts = try JSONDecoder().decode(RepairWordingFacts.self, from: Data(sample.promptDescription.utf8))
        let result = await FoundationModelsRepairWording(deadline: .seconds(10)).word(facts)
        return ModelSubject(value: WordingValue(
            sentence: result.sentence, outcome: result.outcome.name, milliseconds: result.milliseconds
        ))
    }

    /// Each sample's prompt is its facts as JSON; the expected value is the
    /// template, which is what the user sees on any fallback.
    var dataset = ArrayLoader(samples: WordingMatrix.facts.map { facts in
        ModelSample(
            prompt: String(decoding: try! JSONEncoder().encode(facts), as: UTF8.self),
            expected: WordingValue(sentence: facts.template, outcome: "template", milliseconds: 0)
        )
    })

    let accepted = Metric("Accepted")
    let reworded = Metric("Reworded")
    let latency = Metric("Latency ms")

    var evaluators: Evaluators {
        Evaluator { _, subject in
            subject.value.outcome == "accepted"
                ? accepted.passing()
                : accepted.failing(rationale: subject.value.outcome)
        }
        Evaluator { input, subject in
            guard let sentence = subject.value.sentence else { return reworded.ignore() }
            return sentence == input.expected?.sentence
                ? reworded.failing(rationale: "same as the template")
                : reworded.passing(rationale: sentence)
        }
        Evaluator { _, subject in
            latency.scoring(Double(subject.value.milliseconds))
        }
    }

    func aggregateMetrics(using aggregator: inout MetricsAggregator) {
        aggregator.group("Validation") { group in
            group.computeMean(of: accepted)
            group.computeMean(of: reworded)
        }
        aggregator.group("Latency") { group in
            group.computeMean(of: latency)
            group.computeMaximum(of: latency)
        }
    }
}

/// Every action and direction the phrasebook words, in English.
enum WordingMatrix {
    static let label = "red Brick 2 x 4"

    static var facts: [RepairWordingFacts] {
        var all: [RepairWordingFacts] = [
            .init(action: .add, partLabel: label, template: "Add the \(label)."),
            .init(action: .move, partLabel: label, studs: 2, template: "Move the \(label) back to where the guide shows it."),
            .init(action: .rotate, partLabel: label, turn: .quarter, template: "Turn the \(label) a quarter turn."),
            .init(action: .rotate, partLabel: label, turn: .half, template: "Turn the \(label) around."),
            .init(action: .swapColour, partLabel: label, template: "Swap the \(label) for the colour the guide shows."),
            .init(action: .remove, partLabel: label, template: "Take off the \(label)."),
            .init(action: .reAdd, partLabel: label, template: "Put the \(label) back.")
        ]
        let moves: [(RepairWordingDirection, String)] = [
            (.awayFromYou, "one stud away from you"), (.towardYou, "one stud toward you"),
            (.yourLeft, "one stud to your left"), (.yourRight, "one stud to your right"),
            (.screenUp, "one stud toward the top of the screen"), (.screenDown, "one stud toward the bottom of the screen"),
            (.screenLeft, "one stud to the left on screen"), (.screenRight, "one stud to the right on screen")
        ]
        for (direction, words) in moves {
            all.append(.init(action: .move, partLabel: label, direction: direction, studs: 1, template: "Move the \(label) \(words)."))
        }
        return all
    }
}

// Swift Testing refuses `@available` on a suite, and Evaluations is 27-only
// while the package floor is macOS 14 (CI's Xcode 16.4), so availability
// sits on the test function and the evaluation is reached through it.
@Suite("Repair wording evaluations")
struct RepairWordingEvaluationTests {
    @available(macOS 27.0, iOS 27.0, *)
    static var evaluation: RepairWordingEvaluation { .shared }

    static let evaluationInfo: [String: String] = [
        "Instructions": "FoundationModelsRepairWording.instructions",
        "ModelName": "SystemLanguageModel",
        "OSBuild": ProcessInfo.processInfo.operatingSystemVersionString,
        "Feature": "Repair wording (ADR 0017), informational on a Mac"
    ]

    @available(macOS 27.0, iOS 27.0, *)
    @Test(
        "Repair wording over the phrasebook matrix",
        .enabled(if: ProcessInfo.processInfo.environment["BRICKY_FM_LIVE"] == "1"),
        .enabled(if: FoundationModelsRepairWording.readiness() == nil),
        .evaluates(evaluation, info: evaluationInfo)
    )
    func evaluateWording() async throws {
        let result = EvaluationContext.current.result
        // A rejected sentence costs nothing but the rewording, so this is a
        // floor for usefulness, not a safety gate: the validator is that.
        #expect(result.aggregateValue(.mean(of: Self.evaluation.accepted)) >= 0.5)
    }
}
#endif
