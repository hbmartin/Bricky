import XCTest
@testable import Bricky

final class VoxelShapeLibraryTests: XCTestCase {

    /// Every occupied column must be vertically contiguous from a supported base
    /// so the model is buildable (no floating cells).
    private func assertGroundSupported(_ model: VoxelModel, file: StaticString = #filePath, line: UInt = #line) {
        var columns: [Int: [Int]] = [:]
        for v in model.voxels {
            columns[(v.x << 16) | (v.z & 0xFFFF), default: []].append(v.y)
        }
        for (_, ys) in columns {
            let sorted = ys.sorted()
            for i in 1..<max(1, sorted.count) where sorted.count > 1 {
                XCTAssertEqual(sorted[i], sorted[i - 1] + 1,
                               "Column has a vertical gap → would float", file: file, line: line)
            }
        }
    }

    func testHouseKeywordRoutesToHouse() {
        let match = VoxelShapeLibrary.match(for: "a cozy little house", size: .small)
        XCTAssertEqual(match.templateName, "House")
        XCTAssertFalse(match.model.isEmpty)
    }

    func testSynonymRouting() {
        XCTAssertEqual(VoxelShapeLibrary.match(for: "spaceship", size: .small).templateName, "Rocket")
        XCTAssertEqual(VoxelShapeLibrary.match(for: "a puppy", size: .small).templateName, "Dog")
        XCTAssertEqual(VoxelShapeLibrary.match(for: "a jet plane", size: .small).templateName, "Airplane")
    }

    func testUnknownSubjectUsesFallback() {
        let match = VoxelShapeLibrary.match(for: "quantum entanglement", size: .small)
        XCTAssertEqual(match.templateName, "Brick Sculpture")
        XCTAssertFalse(match.model.isEmpty)
    }

    func testAllExamplesAreNonEmptyAndSupported() {
        let subjects = ["house", "tree", "car", "rocket", "robot", "dog", "cat",
                        "fish", "bird", "flower", "heart", "star", "snowman",
                        "castle", "pyramid", "mountain", "boat", "plane", "mystery thing"]
        for subject in subjects {
            let match = VoxelShapeLibrary.match(for: subject, size: .small)
            XCTAssertFalse(match.model.isEmpty, "\(subject) produced no voxels")
            assertGroundSupported(match.model)
        }
    }

    func testAccentColorOverridesPrimary() {
        let match = VoxelShapeLibrary.match(for: "house", size: .small, accent: .purple)
        XCTAssertTrue(match.model.voxels.contains { $0.color == .purple },
                      "Accent colour should appear in the model")
    }

    func testLargerSizeProducesMoreVoxels() {
        let small = VoxelShapeLibrary.match(for: "castle", size: .small).model.voxelCount
        let large = VoxelShapeLibrary.match(for: "castle", size: .large).model.voxelCount
        XCTAssertGreaterThan(large, small)
    }
}
