import XCTest
import simd
@testable import Bricky

/// Cross-step repair (ADR 0015, Proposed): take off what rests on the part
/// top down, fix it, put everything back in authored order. Off unless the
/// flag is set.
final class CrossStepRepairPlannerTests: XCTestCase {
    private var plan: InstructionPlan!
    /// Two bases (0, 1); 2 on 0 and 3 on 1; 4 bridges 2 and 3.
    private let index = PlacementGeometryIndex(
        status: Array(repeating: .offLattice(.noGeometry), count: 5),
        origins: Array(repeating: .zero, count: 5),
        occupancy: [:],
        supports: [[2], [3], [4], [4], []],
        supportedBy: [[], [], [0], [1], [2, 3]]
    )
    private let enabled = RepairFeatureFlags(crossStep: true)

    override func setUpWithError() throws {
        let source = """
        0 Cross-step fixture
        0 Name: main.ldr
        1 4 0 0 0 1 0 0 0 1 0 0 0 1 3001.dat
        1 4 80 0 0 1 0 0 0 1 0 0 0 1 3001.dat
        0 STEP
        1 1 0 -24 0 1 0 0 0 1 0 0 0 1 3001.dat
        1 1 80 -24 0 1 0 0 0 1 0 0 0 1 3001.dat
        0 STEP
        1 14 40 -48 0 1 0 0 0 1 0 0 0 1 3001.dat
        0 STEP
        """
        let document = try LDrawInstructionParser().parse(
            files: [InstructionSourceFile(relativePath: "main.ldr", data: Data(source.utf8))],
            rootRelativePath: "main.ldr"
        )
        plan = try InstructionPlanBuilder().build(
            document: document, title: "Fixture", sourceFilename: "main.ldr", sourceSHA256: String(repeating: "e", count: 64)
        )
        XCTAssertEqual(plan.placementTimeline.count, 5)
    }

    private func observation(_ placement: Int, _ state: PlacementState) -> PlacementObservation {
        PlacementObservation(placement: placement, state: state, evidence: PlacementEvidence())
    }

    private func repair(
        _ state: PlacementState, of placement: Int = 0, observed: [PlacementObservation] = [], built: Int = 5,
        budget: Int = CrossStepRepairPlanner.defaultBudget, flags: RepairFeatureFlags? = nil
    ) -> RepairPlan? {
        CrossStepRepairPlanner.plan(
            anomaly: observation(placement, state), observed: observed, index: index, plan: plan,
            currentStepID: plan.steps[2].id, built: built, budget: budget, flags: flags ?? enabled
        )
    }

    private func summary(_ plan: RepairPlan?) -> [String] {
        (plan?.actions ?? []).map { "\($0.name) \($0.target.placement)" }
    }

    func testTakesOffTopDownFixesThenPutsBackInAuthoredOrder() {
        let plan = repair(.displaced(LatticeOffset(dx: 1)))
        XCTAssertEqual(summary(plan), ["remove 4", "remove 2", "move 0", "re_add 2", "re_add 4"])
        guard case .move(_, let by)? = plan?.actions[2] else { return XCTFail("expected the fix in the middle") }
        XCTAssertEqual(by, LatticeOffset(dx: -1))
        XCTAssertEqual(plan?.withheld, [])
    }

    func testActsOnlyOnAuthoredPlacementsRestingOnThePart() throws {
        let plan = try XCTUnwrap(repair(.rotated(quarterTurns: 1), of: 1))
        XCTAssertEqual(summary(plan), ["remove 4", "remove 3", "rotate 1", "re_add 3", "re_add 4"])
        for action in plan.actions {
            let authored = self.plan.placementTimeline[action.target.placement]
            XCTAssertEqual(action.target.placementID, authored.id)
            XCTAssertEqual(action.target.partReference, authored.partReference)
            XCTAssertTrue([1, 3, 4].contains(action.target.placement), "base 0 and its brick 2 never move")
        }
        guard case .rotate(_, let turns) = plan.actions[2] else { return XCTFail("expected a turn") }
        XCTAssertEqual(turns, 3, "a quarter turn one way is undone by three the other")
        XCTAssertEqual(plan.actions[2].target.stepIndex, 0)
    }

    func testPartsNotYetBuiltNeverMove() {
        XCTAssertEqual(summary(repair(.displaced(LatticeOffset(dz: -1)), built: 4)), ["remove 2", "move 0", "re_add 2"])
    }

    func testOverBudgetIsWithheld() throws {
        let plan = try XCTUnwrap(repair(.displaced(LatticeOffset(dx: 1)), budget: 1))
        XCTAssertTrue(plan.actions.isEmpty)
        XCTAssertEqual(plan.withheld.map(\.reason), [.removalBudgetExceeded])
    }

    func testAMissingBaseUnderPartsSeenInPlaceIsImplausible() throws {
        let implausible = try XCTUnwrap(repair(.absent, observed: [observation(2, .present)]))
        XCTAssertTrue(implausible.actions.isEmpty)
        XCTAssertEqual(implausible.withheld.map(\.reason), [.implausible])
        XCTAssertEqual(summary(repair(.absent)), ["remove 4", "remove 2", "add 0", "re_add 2", "re_add 4"])
    }

    func testFlagOffWithholdsEverything() throws {
        let plan = try XCTUnwrap(repair(.displaced(LatticeOffset(dx: 1)), flags: RepairFeatureFlags()))
        XCTAssertTrue(plan.actions.isEmpty)
        XCTAssertEqual(plan.withheld.map(\.reason), [.crossStepDisabled])
        XCTAssertFalse(RepairFeatureFlags().crossStep, "off by default")
    }

    func testNothingToActOnGivesNoPlan() {
        XCTAssertNil(repair(.present))
        XCTAssertNil(repair(.displaced(LatticeOffset(dy: 1))), "plate steps are observe-only")
        XCTAssertNil(repair(.rotated(quarterTurns: 4)))
        XCTAssertNil(repair(.notObservable(.occluded)))
        XCTAssertNil(repair(.colourMismatch))
        XCTAssertNil(repair(.displaced(LatticeOffset(dx: 1)), of: 4, built: 4), "not built yet")
    }
}
