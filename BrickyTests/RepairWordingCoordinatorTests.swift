import BrickyLanguage
import XCTest
@testable import Bricky

/// The template shows at once; a validated sentence replaces it only for the
/// repair still on screen; a rejection or a stale answer changes nothing.
@MainActor
final class RepairWordingCoordinatorTests: XCTestCase {
    /// Answers from a script, after an optional delay, counting calls.
    private final class ScriptedWording: RepairWordingGenerator, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        let delay: Duration
        let reply: @Sendable (RepairWordingFacts) -> RepairWordingResult

        init(delay: Duration = .zero, reply: @escaping @Sendable (RepairWordingFacts) -> RepairWordingResult) {
            self.delay = delay
            self.reply = reply
        }

        var calls: Int { lock.withLock { count } }

        func word(_ facts: RepairWordingFacts) async -> RepairWordingResult {
            lock.withLock { count += 1 }
            if delay > .zero { try? await Task.sleep(for: delay) }
            return reply(facts)
        }
    }

    private func facts(_ action: RepairWordingAction = .add, label: String = "red Brick 2 x 4") -> RepairWordingFacts {
        RepairWordingFacts(action: action, partLabel: label, template: "Add the \(label).")
    }

    private nonisolated static func accepted(_ sentence: String) -> RepairWordingResult {
        RepairWordingResult(sentence: sentence, outcome: .accepted, modelSentence: sentence, milliseconds: 5)
    }

    private func eventually(_ condition: () -> Bool, timeout: Duration = .seconds(2)) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testTheTemplateShowsFirstThenTheValidatedSentence() async {
        let generator = ScriptedWording { _ in Self.accepted("Pop the red Brick 2 x 4 on.") }
        let coordinator = RepairWordingCoordinator(generator: generator)
        var worded: [String] = []
        var results: [String] = []
        coordinator.onWorded = { worded.append($0) }
        coordinator.onResult = { _, result in results.append(result.outcome.name) }
        XCTAssertEqual(coordinator.update(facts()), "Add the red Brick 2 x 4.")
        await eventually { !worded.isEmpty }
        XCTAssertEqual(worded, ["Pop the red Brick 2 x 4 on."])
        XCTAssertEqual(coordinator.sentence, "Pop the red Brick 2 x 4 on.")
        XCTAssertEqual(results, ["accepted"])
    }

    func testARejectedSentenceKeepsTheTemplateAndIsStillRecorded() async {
        let generator = ScriptedWording { _ in
            RepairWordingResult(sentence: nil, outcome: .rejected(.foreignDirection), modelSentence: "Add it on the left.", milliseconds: 5)
        }
        let coordinator = RepairWordingCoordinator(generator: generator)
        var outcomes: [String] = []
        var worded = 0
        coordinator.onWorded = { _ in worded += 1 }
        coordinator.onResult = { _, result in outcomes.append(result.outcome.name) }
        coordinator.update(facts())
        await eventually { !outcomes.isEmpty }
        XCTAssertEqual(outcomes, ["rejected_foreign_direction"])
        XCTAssertEqual(worded, 0)
        XCTAssertEqual(coordinator.sentence, "Add the red Brick 2 x 4.")
    }

    func testAnAnswerForARepairNoLongerOnScreenIsDropped() async {
        let generator = ScriptedWording(delay: .milliseconds(200)) { facts in Self.accepted("Model: \(facts.partLabel).") }
        let coordinator = RepairWordingCoordinator(generator: generator)
        var worded: [String] = []
        coordinator.onWorded = { worded.append($0) }
        coordinator.update(facts(label: "red Brick 2 x 4"))
        XCTAssertEqual(coordinator.update(facts(label: "blue Plate 1 x 2")), "Add the blue Plate 1 x 2.")
        await eventually { !worded.isEmpty }
        XCTAssertEqual(worded, ["Model: blue Plate 1 x 2."], "the first repair's answer never shows")
    }

    func testRepeatedFactsAreAskedOnce() async {
        let generator = ScriptedWording { _ in Self.accepted("Pop the red Brick 2 x 4 on.") }
        let coordinator = RepairWordingCoordinator(generator: generator)
        var finished = 0
        coordinator.onResult = { _, _ in finished += 1 }
        coordinator.update(facts())
        await eventually { finished == 1 }
        coordinator.update(nil)
        XCTAssertEqual(coordinator.update(facts()), "Pop the red Brick 2 x 4 on.", "the cached sentence shows at once")
        XCTAssertEqual(generator.calls, 1)
        coordinator.reset()
        XCTAssertNil(coordinator.sentence)
    }

    func testWithoutAGeneratorItIsTheTemplate() {
        let coordinator = RepairWordingCoordinator(generator: nil)
        XCTAssertEqual(coordinator.update(facts()), "Add the red Brick 2 x 4.")
        XCTAssertNil(coordinator.update(nil))
    }

    // MARK: - Facts from a plan

    private func ref(_ placement: Int) -> PlacementRef {
        PlacementRef(placement: placement, placementID: "p\(placement)", stepIndex: 3, partReference: "3001.dat", colourCode: 4)
    }

    func testFactsMirrorWhatTheTemplateSays() throws {
        let labels = [5: "red Brick 2 x 4"]
        let oneStud = try XCTUnwrap(RepairWordingFacts(
            actions: [.move(ref(5), by: LatticeOffset(dx: -1))], direction: .yourLeft, labels: labels, template: "t"
        ))
        XCTAssertEqual(oneStud.action, .move)
        XCTAssertEqual(oneStud.studs, 1)
        XCTAssertEqual(oneStud.direction, .yourLeft)
        XCTAssertEqual(oneStud.partLabel, "red Brick 2 x 4")

        // Two studs: the template names no direction, so the facts hold none.
        let twoStuds = try XCTUnwrap(RepairWordingFacts(
            actions: [.move(ref(5), by: LatticeOffset(dx: 1, dz: 1))], direction: .towardYou, labels: labels, template: "t"
        ))
        XCTAssertEqual(twoStuds.studs, 2)
        XCTAssertNil(twoStuds.direction)

        let half = try XCTUnwrap(RepairWordingFacts(actions: [.rotate(ref(5), quarterTurns: 2)], direction: nil, labels: labels, template: "t"))
        XCTAssertEqual(half.turn, .half)
        let swap = try XCTUnwrap(RepairWordingFacts(actions: [.swapColour(ref(5), expected: 4)], direction: nil, labels: labels, template: "t"))
        XCTAssertEqual(swap.action, .swapColour)

        let several = try XCTUnwrap(RepairWordingFacts(
            actions: [.move(ref(5), by: LatticeOffset(dx: 1)), .move(ref(6), by: LatticeOffset(dx: 1))],
            direction: .yourRight, labels: labels, template: "t"
        ))
        XCTAssertEqual(several.partCount, 2)
        XCTAssertEqual(several.partLabel, RepairPhrasebook.subject(for: [.move(ref(5), by: LatticeOffset(dx: 1)), .move(ref(6), by: LatticeOffset(dx: 1))], labels: labels))
        XCTAssertNil(RepairWordingFacts(actions: [], direction: nil, labels: labels, template: "t"))
    }

    func testTheLanguageLayerRunsOnlyWhenOnAndInEnglish() {
        XCTAssertNil(RepairWordingSource.generator(enabled: false, preferredLocalizations: ["en"]))
        XCTAssertNil(RepairWordingSource.generator(enabled: true, preferredLocalizations: ["fr"]))
        #if canImport(FoundationModels)
        XCTAssertNotNil(RepairWordingSource.generator(enabled: true, preferredLocalizations: ["en"]))
        #else
        XCTAssertNil(RepairWordingSource.generator(enabled: true, preferredLocalizations: ["en"]), "no system model to ask")
        #endif
    }
}
