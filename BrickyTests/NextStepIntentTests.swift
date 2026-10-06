import SwiftData
import XCTest
@testable import Bricky

/// Siri's "next step" (ADR 0016): refuses when nobody is at the guide, asks
/// before anything moves, and acts only on the step the user agreed to.
@MainActor
final class NextStepIntentTests: XCTestCase {
    private struct InlineLoader: PlanLoading {
        let plan: InstructionPlan
        func loadPlan(for model: StoredInstructionModel) throws -> InstructionPlan { plan }
    }

    private struct Declined: Error {}

    private var container: ModelContainer!
    private var plan: InstructionPlan!
    private var model: StoredInstructionModel!

    override func setUp() async throws {
        container = try ModelContainer(
            for: InstructionPersistence.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let source = """
        0 Intent fixture
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
            document: document, title: "Fixture", sourceFilename: "main.ldr", sourceSHA256: String(repeating: "b", count: 64)
        )
        model = StoredInstructionModel(plan: plan)
        container.mainContext.insert(model)
        try container.mainContext.save()
    }

    private func session(completed: Int = 0, attending: Bool = true) throws -> BuildSessionController {
        model.currentStepIndex = completed
        let session = BuildSessionController()
        try session.open(model, loader: InlineLoader(plan: plan), context: container.mainContext)
        session.setAttending(attending, by: "ar_guide")
        return session
    }

    func testTheIntentNeverOpensTheApp() {
        XCTAssertEqual(NextStepIntent.supportedModes, .background)
    }

    func testUnattendedRefusesWithoutAsking() async throws {
        let session = try session(attending: false)
        var asked = false
        let reply = try await NextStepHandler(session: session).run { _ in asked = true }
        XCTAssertFalse(asked, "nobody is there to confirm")
        XCTAssertEqual(reply, "Open the build guide to go on.")
        XCTAssertEqual(model.currentStepIndex, 0)
    }

    func testDecliningLeavesProgressUnchanged() async throws {
        let session = try session()
        do {
            _ = try await NextStepHandler(session: session).run { _ in throw Declined() }
            XCTFail("declining must end the intent")
        } catch is Declined {}
        XCTAssertEqual(model.currentStepIndex, 0)
        XCTAssertEqual(session.cursorIndex, 0)
        XCTAssertNil(session.lastConfirmationSource)
    }

    func testConfirmingAdvancesAndSaysTheStep() async throws {
        let session = try session()
        var prompt: String?
        let reply = try await NextStepHandler(session: session).run { prompt = $0 }
        XCTAssertEqual(prompt, "Mark step 1 done and show step 2?")
        XCTAssertEqual(reply, "Step 2 of 3.")
        XCTAssertEqual(model.currentStepIndex, 1)
        XCTAssertEqual(session.lastConfirmationSource, .appIntent)
    }

    func testANegativeCheckAsksWithTheRepairAndGoesOnAnyway() async throws {
        let session = try session()
        session.reportVerification(
            StepVerification(
                stepID: plan.steps[0].id, verdict: .misplaced(offsetStuds: SIMD2(1, 0)), detectability: .strong,
                deltaPixels: 400, framesUsed: 10, completeFraction: 0, incompleteFraction: 0,
                registrationQuality: .none, timestamp: 0
            ),
            repairSentence: "Move the red Brick 2 x 4 one stud to your left."
        )
        var prompt: String?
        _ = try await NextStepHandler(session: session).run { prompt = $0 }
        XCTAssertEqual(prompt, "Move the red Brick 2 x 4 one stud to your left. Go on anyway?")
        XCTAssertEqual(model.currentStepIndex, 1, "confirming the hold is the user's next anyway")
    }

    func testTheGuideMovingDuringConfirmationChangesNothing() async throws {
        let session = try session(completed: 1)
        let reply = try await NextStepHandler(session: session).run { _ in session.browse(by: -1) }
        XCTAssertEqual(reply, "The guide moved on, so nothing changed.")
        XCTAssertEqual(model.currentStepIndex, 1)
    }

    func testTheLastStepFinishesTheBuild() async throws {
        let session = try session(completed: 2)
        var prompt: String?
        let reply = try await NextStepHandler(session: session).run { prompt = $0 }
        XCTAssertEqual(prompt, "Mark step 3 done and finish the build?")
        XCTAssertEqual(reply, "That was the last step. The build is done.")
        XCTAssertTrue(session.isFinished)
        let again = try await NextStepHandler(session: session).run { _ in XCTFail("nothing left to confirm") }
        XCTAssertEqual(again, "That was the last step.")
    }
}
