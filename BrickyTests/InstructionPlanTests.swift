import XCTest
@testable import Bricky

final class InstructionPlanTests: XCTestCase {
    func testBuildableSubmodelExpandsBeforeParentStepInFinalFrame() throws {
        let source = """
        0 FILE main.ldr
        1 4 100 0 0 1 0 0 0 1 0 0 0 1 module.ldr
        0 STEP
        0 FILE module.ldr
        1 16 20 0 0 1 0 0 0 1 0 0 0 1 3005.dat
        0 STEP
        """
        let document = try LDrawInstructionParser().parse(
            files: [.init(relativePath: "nested.mpd", data: Data(source.utf8))],
            rootRelativePath: "nested.mpd"
        )
        let plan = try InstructionPlanBuilder().build(
            document: document,
            title: "Nested",
            sourceFilename: "nested.mpd",
            sourceSHA256: String(repeating: "0", count: 64)
        )
        XCTAssertEqual(plan.steps.count, 2)
        XCTAssertTrue(plan.steps[0].instancePath.contains("module.ldr"))
        XCTAssertEqual(plan.placementTimeline[0].transform.x, 120)
        XCTAssertEqual(plan.placementTimeline[0].colorCode, 4)
        XCTAssertTrue(plan.steps[1].addedPlacementRange.isEmpty)
    }

    func testLDrawScaleIsFixedPhysicalScale() {
        let transform = LDrawTransform(x: 20, y: 24, z: -10)
        XCTAssertEqual(transform.translationInMeters.x, 0.008, accuracy: 0.000_001)
        XCTAssertEqual(transform.translationInMeters.y, -0.0096, accuracy: 0.000_001)
        XCTAssertEqual(transform.translationInMeters.z, -0.004, accuracy: 0.000_001)
    }

    func testRepeatedSubmodelInstancesHaveDistinctPathsAndInheritedColor() throws {
        let source = """
        0 FILE main.ldr
        1 4 0 0 0 1 0 0 0 1 0 0 0 1 module.ldr
        0 STEP
        1 1 100 0 0 1 0 0 0 1 0 0 0 1 module.ldr
        0 STEP
        0 FILE module.ldr
        1 16 10 0 0 1 0 0 0 1 0 0 0 1 3005.dat
        0 STEP
        """
        let document = try LDrawInstructionParser().parse(
            files: [.init(relativePath: "repeated.mpd", data: Data(source.utf8))],
            rootRelativePath: "repeated.mpd"
        )
        let plan = try InstructionPlanBuilder().build(
            document: document,
            title: "Repeated",
            sourceFilename: "repeated.mpd",
            sourceSHA256: String(repeating: "1", count: 64)
        )

        XCTAssertEqual(plan.steps.count, 4)
        XCTAssertEqual(plan.placementTimeline.map(\.transform.x), [10, 110])
        XCTAssertEqual(plan.placementTimeline.map(\.colorCode), [4, 1])
        XCTAssertNotEqual(plan.steps[0].instancePath, plan.steps[2].instancePath)
    }
}
