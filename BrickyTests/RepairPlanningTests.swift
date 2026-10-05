import XCTest
import simd
@testable import Bricky

/// Repairs are derived, never generated: the planner undoes what was
/// measured, and the wording says which way from where the user stands.
final class RepairPlanningTests: XCTestCase {
    // MARK: - Camera-relative direction

    /// A camera at `eye` looking at the origin, y up.
    private func camera(eye: SIMD3<Float>) -> simd_float4x4 {
        let zAxis = simd_normalize(eye)
        let xAxis = simd_normalize(simd_cross(SIMD3(0, 1, 0), zAxis))
        let yAxis = simd_cross(zAxis, xAxis)
        return simd_float4x4(SIMD4(xAxis, 0), SIMD4(yAxis, 0), SIMD4(zAxis, 0), SIMD4(eye, 1))
    }

    /// Standing at +z looking toward −z: away is −z, your right is +x.
    private var frontCamera: simd_float4x4 { camera(eye: SIMD3(0, 0.3, 0.4)) }

    private func told(_ offset: LatticeOffset, model: simd_float4x4 = matrix_identity_float4x4,
                      view: simd_float4x4, rotation: ScreenRotation) -> RelativeDirection? {
        let bearing = CameraRelativeDirection.bearingDegrees(
            correction: CameraRelativeDirection.worldCorrection(offset, worldFromModel: model),
            worldFromCamera: view, rotation: rotation
        )
        var stabilizer = DirectionStabilizer()
        return stabilizer.update(bearing: bearing, pitchDegrees: CameraRelativeDirection.pitchDegrees(worldFromCamera: view), at: 0)
    }

    func testLandscapeAxesFromTheFront() {
        XCTAssertEqual(told(LatticeOffset(dx: 1), view: frontCamera, rotation: .landscapeRight), .yourRight)
        XCTAssertEqual(told(LatticeOffset(dz: -1), view: frontCamera, rotation: .landscapeRight), .awayFromYou)
        XCTAssertEqual(told(LatticeOffset(dz: 1), view: frontCamera, rotation: .landscapeRight), .towardYou)
    }

    /// The phone turned to portrait sees the same table: the words for a
    /// move must not depend on how the user holds it, once the camera
    /// itself is rotated to match.
    func testPortraitAgreesWithLandscapeForTheSamePose() {
        // Rolling the camera −90° about its view axis is how portrait holds
        // the sensor relative to landscape-right.
        let roll = simd_float4x4(simd_quatf(angle: -.pi / 2, axis: SIMD3(0, 0, 1)))
        let portraitCamera = frontCamera * roll
        XCTAssertEqual(told(LatticeOffset(dx: 1), view: portraitCamera, rotation: .portrait), .yourRight)
        XCTAssertEqual(told(LatticeOffset(dz: -1), view: portraitCamera, rotation: .portrait), .awayFromYou)
    }

    func testModelYawTurnsTheCorrection() {
        // The model turned a quarter: its +x now points along world −z.
        let yaw = simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3(0, 1, 0)))
        XCTAssertEqual(told(LatticeOffset(dx: 1), model: yaw, view: frontCamera, rotation: .landscapeRight), .awayFromYou)
    }

    func testStraightDownSpeaksInScreenTerms() {
        let topDown = camera(eye: SIMD3(0, 0.5, 0.001))
        XCTAssertGreaterThan(CameraRelativeDirection.pitchDegrees(worldFromCamera: topDown), 70)
        let direction = told(LatticeOffset(dx: 1), view: topDown, rotation: .landscapeRight)
        XCTAssertEqual(direction, .screenRight)
    }

    // MARK: - Stabilizer

    func testNoFirstWordNearABoundary() {
        var stabilizer = DirectionStabilizer()
        XCTAssertNil(stabilizer.update(bearing: 47, pitchDegrees: 30, at: 0), "within 8° of 45° is a coin toss")
        XCTAssertEqual(stabilizer.update(bearing: 60, pitchDegrees: 30, at: 0.1), .yourRight)
    }

    func testNoFlipInsideTheHysteresisBand() {
        var stabilizer = DirectionStabilizer()
        _ = stabilizer.update(bearing: 20, pitchDegrees: 30, at: 0)
        for time in stride(from: 0.1, to: 3, by: 0.1) {
            XCTAssertEqual(stabilizer.update(bearing: 45 + 7, pitchDegrees: 30, at: time), .awayFromYou)
        }
    }

    func testAFlipNeedsOneSecondOfDwell() {
        var stabilizer = DirectionStabilizer()
        _ = stabilizer.update(bearing: 20, pitchDegrees: 30, at: 0)
        XCTAssertEqual(stabilizer.update(bearing: 80, pitchDegrees: 30, at: 1.0), .awayFromYou)
        XCTAssertEqual(stabilizer.update(bearing: 80, pitchDegrees: 30, at: 1.9), .awayFromYou)
        XCTAssertEqual(stabilizer.update(bearing: 80, pitchDegrees: 30, at: 2.0), .yourRight)
    }

    func testTopDownHasPitchHysteresis() {
        var stabilizer = DirectionStabilizer()
        _ = stabilizer.update(bearing: 0, pitchDegrees: 72, at: 0)
        XCTAssertTrue(stabilizer.topDown)
        _ = stabilizer.update(bearing: 0, pitchDegrees: 65, at: 0.1)
        XCTAssertTrue(stabilizer.topDown, "stays screen-relative until below 62°")
        _ = stabilizer.update(bearing: 0, pitchDegrees: 60, at: 0.2)
        XCTAssertFalse(stabilizer.topDown)
    }

    // MARK: - Planner

    private func ref(_ placement: Int) -> PlacementRef {
        PlacementRef(placement: placement, placementID: "p\(placement)", stepIndex: 2, partReference: "3001.dat", colourCode: 4)
    }

    private var context: RepairPlanner.Context {
        RepairPlanner.Context(stepID: "main.ldr#3", stepIndex: 2, added: [ref(5), ref(6)])
    }

    func testAMisplacedStepMovesEveryAddedPartBack() throws {
        let plan = try XCTUnwrap(RepairPlanner.plan(verdict: .misplaced(offsetStuds: SIMD2(1, 0)), context: context))
        XCTAssertEqual(plan.actions, [.move(ref(5), by: LatticeOffset(dx: -1)), .move(ref(6), by: LatticeOffset(dx: -1))])
        XCTAssertEqual(plan.source, .stepVerdict)
        XCTAssertNil(RepairPlanner.plan(verdict: .complete, context: context))
        XCTAssertNil(RepairPlanner.plan(verdict: .incomplete, context: context), "a missing part has no measured fix")
    }

    func testDiffPlansWaitForTheirFlag() {
        let diff = BuildDiff(stepID: "main.ldr#3", observations: [
            PlacementObservation(placement: 5, state: .absent, evidence: PlacementEvidence())
        ], framesUsed: 9)
        XCTAssertNil(RepairPlanner.plan(diff: diff, context: context, flags: RepairFeatureFlags()))
    }

    func testDiffPlansNeverTouchAPresentPart() throws {
        let diff = BuildDiff(stepID: "main.ldr#3", observations: [
            PlacementObservation(placement: 5, state: .present, evidence: PlacementEvidence()),
            PlacementObservation(placement: 6, state: .rotated(quarterTurns: 1), evidence: PlacementEvidence()),
            PlacementObservation(placement: 2, state: .absent, evidence: PlacementEvidence())
        ], framesUsed: 9)
        let plan = try XCTUnwrap(RepairPlanner.plan(diff: diff, context: context, flags: RepairFeatureFlags(buildDiffInput: true)))
        XCTAssertEqual(plan.actions, [.rotate(ref(6), quarterTurns: 3)])
        XCTAssertFalse(plan.actions.contains { $0.target.placement == 5 })
        XCTAssertFalse(plan.actions.contains { $0.target.placement == 2 }, "an earlier step's part is not this plan's")
    }

    func testUnseenPartsAreWithheldNotGuessed() throws {
        let diff = BuildDiff(stepID: "main.ldr#3", observations: [
            PlacementObservation(placement: 5, state: .notObservable(.occluded), evidence: PlacementEvidence()),
            PlacementObservation(placement: 6, state: .displaced(LatticeOffset(dy: 1)), evidence: PlacementEvidence())
        ], framesUsed: 9)
        let plan = try XCTUnwrap(RepairPlanner.plan(diff: diff, context: context, flags: RepairFeatureFlags(buildDiffInput: true)))
        XCTAssertTrue(plan.actions.isEmpty, "plate steps are never acted on")
        XCTAssertEqual(plan.withheld.map(\.reason), [.notObservable])
    }
}
