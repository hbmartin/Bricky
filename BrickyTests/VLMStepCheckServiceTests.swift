import RecoveryEvidenceKit
import XCTest
@testable import Bricky

/// The check's target falls back honestly, alternates cover exactly the
/// targets not used, and staged declarations label checks either way.
@MainActor
final class VLMStepCheckServiceTests: XCTestCase {
    private func plan() throws -> InstructionPlan {
        let source = """
        0 Check fixture
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
        return try InstructionPlanBuilder().build(
            document: document, title: "Fixture", sourceFilename: "main.ldr", sourceSHA256: String(repeating: "a", count: 64)
        )
    }

    func testStepCheckResultMirrorsTheSchemaSource() {
        XCTAssertEqual(StepCheckResult.allCases.map(\.rawValue), VerdictSchemasV1.checkVerdictValues)
        XCTAssertEqual(StepCheckResult.allCases.map(\.rawValue), CheckVerdictV1.allCases.map(\.rawValue))
    }

    func testRegisteredFallsBackToTheGuideCameraOutsideAR() {
        XCTAssertEqual(VLMStepCheckService.resolvedTarget(requested: .registered, registeredAvailable: false), .guideCamera)
        XCTAssertEqual(VLMStepCheckService.resolvedTarget(requested: .registered, registeredAvailable: true), .registered)
        XCTAssertEqual(VLMStepCheckService.resolvedTarget(requested: .guideCamera, registeredAvailable: true), .guideCamera)
    }

    func testAlternatesAreEveryOtherRenderableTarget() {
        XCTAssertEqual(VLMStepCheckService.alternateTargets(used: .guideCamera, registeredAvailable: true), [.registered])
        XCTAssertEqual(VLMStepCheckService.alternateTargets(used: .registered, registeredAvailable: true), [.guideCamera])
        XCTAssertEqual(VLMStepCheckService.alternateTargets(used: .guideCamera, registeredAvailable: false), [])
    }

    func testStagedDeclarationsLabelChecksWhetherOrNotConfirmed() throws {
        let plan = try plan()
        let step = plan.steps[2]
        // Declared one step short of the checked step: a negative.
        let short = StagedFixtureDeclaration(
            expectedCompletedCount: 2, lighting: .bright, occlusion: .none, physicalCase: true, legalUseConfirmed: true
        )
        let unconfirmed = VLMStepCheckService.groundTruth(staged: short, plan: plan, step: step, confirmed: false)
        XCTAssertEqual(unconfirmed.kind, .staged)
        XCTAssertEqual(unconfirmed.expectedCompletedCount, 2)
        XCTAssertEqual(unconfirmed.expectedStepID, plan.steps[1].id)
        XCTAssertNil(unconfirmed.confirmedCompletedCount)

        // The user's confirm is kept as a cross-check, never as the label.
        let confirmed = VLMStepCheckService.groundTruth(staged: short, plan: plan, step: step, confirmed: true)
        XCTAssertEqual(confirmed.expectedCompletedCount, 2)
        XCTAssertEqual(confirmed.confirmedCompletedCount, 3)

        let notStarted = StagedFixtureDeclaration(
            expectedCompletedCount: 0, lighting: .dim, occlusion: .partial, physicalCase: true, legalUseConfirmed: true
        )
        XCTAssertEqual(
            VLMStepCheckService.groundTruth(staged: notStarted, plan: plan, step: step, confirmed: false).expectedStepID,
            plan.stepZeroID
        )
    }

    func testUnstagedChecksAreLabeledOnlyByAConfirm() throws {
        let plan = try plan()
        let step = plan.steps[1]
        XCTAssertEqual(VLMStepCheckService.groundTruth(staged: nil, plan: plan, step: step, confirmed: false).kind, .unlabeled)
        let confirmed = VLMStepCheckService.groundTruth(staged: nil, plan: plan, step: step, confirmed: true)
        XCTAssertEqual(confirmed.kind, .confirmed)
        XCTAssertEqual(confirmed.expectedCompletedCount, 2)
        XCTAssertEqual(confirmed.expectedStepID, step.id)
    }
}
