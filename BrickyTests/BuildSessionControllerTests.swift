import SwiftData
import XCTest
@testable import Bricky

/// Progress has one owner. These pin the behaviour every view now relies
/// on: where a model opens, what a confirm saves, what browsing does not.
@MainActor
final class BuildSessionControllerTests: XCTestCase {
    private struct InlineLoader: PlanLoading {
        let plan: InstructionPlan
        func loadPlan(for model: StoredInstructionModel) throws -> InstructionPlan { plan }
    }

    private var container: ModelContainer!
    private var context: ModelContext!
    private var plan: InstructionPlan!
    private var model: StoredInstructionModel!

    override func setUp() async throws {
        container = try ModelContainer(
            for: InstructionPersistence.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = container.mainContext
        let source = """
        0 Session fixture
        0 Name: main.ldr
        1 4 0 0 0 1 0 0 0 1 0 0 0 1 3001.dat
        0 STEP
        1 1 0 -24 0 1 0 0 0 1 0 0 0 1 3001.dat
        0 STEP
        1 14 0 -48 0 1 0 0 0 1 0 0 0 1 3001.dat
        0 STEP
        """
        let document = try LDrawInstructionParser().parse(
            files: [InstructionSourceFile(relativePath: "main.ldr", data: Data(source.utf8))],
            rootRelativePath: "main.ldr"
        )
        plan = try InstructionPlanBuilder().build(
            document: document, title: "Fixture", sourceFilename: "main.ldr", sourceSHA256: String(repeating: "a", count: 64)
        )
        XCTAssertEqual(plan.steps.count, 3)
        model = StoredInstructionModel(plan: plan)
        context.insert(model)
        try context.save()
    }

    private func openedSession(completed: Int = 0) throws -> BuildSessionController {
        model.currentStepIndex = completed
        let session = BuildSessionController()
        try session.open(model, loader: InlineLoader(plan: plan), context: context)
        return session
    }

    func testOpenLandsOnTheNextStepToBuild() throws {
        let session = try openedSession(completed: 2)
        XCTAssertEqual(session.cursorIndex, 2)
        XCTAssertEqual(session.cursorStep?.id, plan.steps[2].id)
        XCTAssertFalse(session.isFinished)
    }

    func testConfirmSavesProgressAndAdvances() throws {
        let session = try openedSession()
        session.confirm(plan.steps[0], source: .guide)
        XCTAssertEqual(model.currentStepIndex, 1)
        XCTAssertEqual(model.confirmedLastCompletedStepID, plan.steps[0].id)
        XCTAssertEqual(session.cursorIndex, 1)
        XCTAssertEqual(session.lastConfirmationSource, .guide)
        XCTAssertNil(session.lastPersistenceError)
        XCTAssertFalse(context.hasChanges, "a confirm is saved, not left pending")
    }

    func testConfirmingTheLastStepFinishesWithoutRunningOffTheEnd() throws {
        let session = try openedSession(completed: 2)
        session.confirm(plan.steps[2], source: .arVerified)
        XCTAssertEqual(model.currentStepIndex, 3)
        XCTAssertEqual(session.cursorIndex, 2)
        XCTAssertTrue(session.isFinished)
    }

    func testRecoverySetsProgressOutright() throws {
        let session = try openedSession()
        session.setCompletedCount(2, source: .recovery)
        XCTAssertEqual(model.currentStepIndex, 2)
        XCTAssertEqual(model.confirmedLastCompletedStepID, plan.steps[1].id)
        XCTAssertEqual(session.cursorStep?.id, plan.steps[2].id)
        session.setCompletedCount(0, source: .recovery)
        XCTAssertNil(model.confirmedLastCompletedStepID, "step zero has no completed step")
        session.setCompletedCount(99, source: .recovery)
        XCTAssertEqual(model.currentStepIndex, 3, "clamped to the plan")
    }

    func testConfirmAfterBrowsingBackKeepsProgress() throws {
        let session = try openedSession(completed: 2)
        model.confirmedLastCompletedStepID = plan.steps[1].id
        session.browse(by: -2)
        XCTAssertEqual(session.cursorStep?.id, plan.steps[0].id)
        session.confirm(plan.steps[0], source: .guide)
        XCTAssertEqual(model.currentStepIndex, 2, "confirming an earlier step must not rewind progress")
        XCTAssertEqual(model.confirmedLastCompletedStepID, plan.steps[1].id)
        XCTAssertEqual(session.cursorIndex, 1, "Next on a browsed-back step browses forward")
        session.confirm(plan.steps[1], source: .guide)
        XCTAssertEqual(model.currentStepIndex, 2)
        XCTAssertEqual(session.cursorIndex, 2, "back at the frontier")
        session.confirm(plan.steps[2], source: .guide)
        XCTAssertEqual(model.currentStepIndex, 3, "the frontier step still advances")
    }

    func testBrowsingNeverSaves() throws {
        let session = try openedSession(completed: 1)
        session.browse(by: 1)
        session.browse(by: 5)
        XCTAssertEqual(session.cursorIndex, 2)
        session.browse(by: -9)
        XCTAssertEqual(session.cursorIndex, 0)
        XCTAssertEqual(model.currentStepIndex, 1)
    }

    private func verification(_ verdict: StepVerdict, step: Int) -> StepVerification {
        StepVerification(
            stepID: plan.steps[step].id, verdict: verdict, detectability: .strong, deltaPixels: 400, framesUsed: 10,
            completeFraction: 0, incompleteFraction: 0, registrationQuality: .none, timestamp: 0
        )
    }

    func testVoiceNextIsRefusedWhenNoGuideIsAttending() throws {
        let session = try openedSession()
        XCTAssertEqual(session.requestAdvance(.nextAnyway, source: .voice, verification: nil), .refuse(.unattended))
        XCTAssertEqual(model.currentStepIndex, 0)
        session.setAttending(true, by: "ar_guide")
        session.setAttending(true, by: "guide")
        session.setAttending(false, by: "ar_guide")
        XCTAssertTrue(session.isAttended, "another guide is still on screen")
        XCTAssertEqual(session.requestAdvance(.next, source: .voice, verification: nil), .advance)
        XCTAssertEqual(model.currentStepIndex, 1)
        XCTAssertEqual(session.lastConfirmationSource, .voice)
    }

    func testVoiceNextHoldsOnAMisplacedStepWithItsRepair() throws {
        let session = try openedSession()
        session.setAttending(true, by: "ar_guide")
        let decision = session.requestAdvance(
            .next, source: .voice, verification: verification(.misplaced(offsetStuds: SIMD2(1, 0)), step: 0)
        )
        guard case .holdAndSpeak(let repair?) = decision else {
            return XCTFail("expected a hold with a repair, got \(decision)")
        }
        XCTAssertEqual(repair.actions.count, 1)
        XCTAssertEqual(model.currentStepIndex, 0, "holding saves nothing")
        XCTAssertEqual(session.requestAdvance(.nextAnyway, source: .voice, verification: nil), .advance)
        XCTAssertEqual(model.currentStepIndex, 1)
    }

    func testAVerdictAboutAnotherStepIsIgnored() throws {
        let session = try openedSession(completed: 1)
        session.setAttending(true, by: "ar_guide")
        XCTAssertEqual(session.requestAdvance(.next, source: .voice, verification: verification(.incomplete, step: 0)), .advance)
        XCTAssertEqual(model.currentStepIndex, 2)
    }

    func testVoiceNextOnABrowsedBackStepOnlyBrowses() throws {
        let session = try openedSession(completed: 2)
        session.setAttending(true, by: "ar_guide")
        session.browse(by: -2)
        XCTAssertEqual(session.requestAdvance(.nextAnyway, source: .voice, verification: nil), .browseForward)
        XCTAssertEqual(session.cursorIndex, 1)
        XCTAssertEqual(model.currentStepIndex, 2, "never rewinds, never skips")
    }

    func testVoiceNextAfterTheLastStepIsRefused() throws {
        let session = try openedSession(completed: 3)
        session.setAttending(true, by: "ar_guide")
        XCTAssertEqual(session.requestAdvance(.next, source: .voice, verification: nil), .refuse(.finished))
    }

    func testReopeningTheSameModelKeepsTheBrowsingPosition() throws {
        let session = try openedSession(completed: 0)
        session.browse(by: 2)
        try session.open(model, loader: InlineLoader(plan: plan), context: context)
        XCTAssertEqual(session.cursorIndex, 2, "returning from AR must not snap the guide back")
    }
}
