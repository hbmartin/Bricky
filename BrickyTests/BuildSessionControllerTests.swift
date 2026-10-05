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

    func testReopeningTheSameModelKeepsTheBrowsingPosition() throws {
        let session = try openedSession(completed: 0)
        session.browse(by: 2)
        try session.open(model, loader: InlineLoader(plan: plan), context: context)
        XCTAssertEqual(session.cursorIndex, 2, "returning from AR must not snap the guide back")
    }
}
