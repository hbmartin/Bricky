import XCTest
@testable import Bricky

final class InferenceArmSchedulerTests: XCTestCase {
    private let suite = "InferenceArmSchedulerTests"
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func scheduler(_ mode: InferenceArmScheduler.Mode) -> InferenceArmScheduler {
        let scheduler = InferenceArmScheduler(defaults: defaults)
        scheduler.plan = .init(mode: mode, variant: RecoveryInferenceVariant(decode: .feedAll, uniqueSlots: true))
        return scheduler
    }

    func testWithoutTheEvidenceToggleEveryCallIsBaseline() {
        let arms = scheduler(.interleave)
        XCTAssertEqual(arms.next(evidenceEnabled: false), .baseline)
        XCTAssertEqual(arms.next(evidenceEnabled: false), .baseline)
    }

    func testInterleaveAlternatesStartingWithControl() {
        let arms = scheduler(.interleave)
        let ids = (0..<4).map { _ in arms.next(evidenceEnabled: true) }
        XCTAssertEqual(ids.map(\.armID), ["A", "B", "A", "B"])
        XCTAssertEqual(ids[0].id, "baseline")
        XCTAssertEqual(ids[1].id, "decode=feed_all,unique_slots")
    }

    func testSingleRunsTheVariantEveryTime() {
        let arms = scheduler(.single)
        XCTAssertEqual(arms.next(evidenceEnabled: true).armID, "B")
        XCTAssertEqual(arms.next(evidenceEnabled: true).id, "decode=feed_all,unique_slots")
    }

    func testAnInvalidVariantRunsTheUnlabelledBaseline() {
        let arms = InferenceArmScheduler(defaults: defaults)
        arms.plan = .init(mode: .single, variant: RecoveryInferenceVariant(vote: .logprob))
        XCTAssertEqual(arms.next(evidenceEnabled: true), .baseline, "logprob without probe would measure nothing")
    }

    func testOffIsBaselineAndThePlanPersists() {
        XCTAssertEqual(scheduler(.off).next(evidenceEnabled: true), .baseline)
        XCTAssertEqual(InferenceArmScheduler(defaults: defaults).plan.mode, .off)
        _ = scheduler(.single)
        XCTAssertEqual(InferenceArmScheduler(defaults: defaults).plan.mode, .single)
    }
}
