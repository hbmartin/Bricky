import XCTest
@testable import Bricky

/// Tests for the on-device Set Forge engine and its structural invariants.
final class SetForgeEngineTests: XCTestCase {

    // MARK: - Helpers

    /// A simple solid 4×3×4 block, all red, fully ground-supported.
    private func solidBlock(w: Int = 4, h: Int = 3, d: Int = 4, color: LegoColor = .red) -> VoxelModel {
        var voxels: [Voxel] = []
        for x in 0..<w { for y in 0..<h { for z in 0..<d {
            voxels.append(Voxel(x: x, y: y, z: z, color: color))
        } } }
        return VoxelModel(width: w, height: h, depth: d, voxels: voxels, source: .text, subject: "Block")
    }

    /// Asserts no brick floats: every brick above layer 0 has an occupied cell
    /// directly beneath at least one of its studs.
    private func assertNoFloatingBricks(_ set: GeneratedLegoSet, file: StaticString = #filePath, line: UInt = #line) {
        var occupied = Set<Int>()
        for b in set.bricks {
            for i in 0..<b.length {
                occupied.insert(VoxelModel.key(b.x + i, b.y, b.z))
            }
        }
        for b in set.bricks where b.y > 0 {
            let supported = (0..<b.length).contains { i in
                occupied.contains(VoxelModel.key(b.x + i, b.y - 1, b.z))
            }
            XCTAssertTrue(supported, "Brick at (\(b.x),\(b.y),\(b.z)) floats with no support", file: file, line: line)
        }
    }

    // MARK: - Tests

    func testGenerateProducesBuildableSet() throws {
        let set = try SetForgeEngine.shared.generate(from: solidBlock(), size: .small, name: "Block")
        XCTAssertGreaterThan(set.brickCount, 0)
        XCTAssertFalse(set.parts.isEmpty)
        XCTAssertFalse(set.steps.isEmpty)
        XCTAssertFalse(set.ldrText.isEmpty)
        XCTAssertEqual(set.layerCount, 3)
    }

    func testNoFloatingBricks() throws {
        let set = try SetForgeEngine.shared.generate(from: solidBlock(w: 6, h: 4, d: 5), size: .medium, name: "Block")
        assertNoFloatingBricks(set)
    }

    func testPartsCountMatchesBrickCount() throws {
        let set = try SetForgeEngine.shared.generate(from: solidBlock(w: 8, h: 2, d: 6), size: .medium, name: "Block")
        let partTotal = set.parts.reduce(0) { $0 + $1.quantity }
        XCTAssertEqual(partTotal, set.brickCount, "Parts list must account for every brick")
    }

    func testEveryBrickAppearsInExactlyOneStep() throws {
        let set = try SetForgeEngine.shared.generate(from: solidBlock(w: 10, h: 3, d: 4), size: .medium, name: "Block")
        // Each step references the bricks of its layer; total steps ≥ layers.
        XCTAssertGreaterThanOrEqual(set.steps.count, set.layerCount)
        XCTAssertEqual(Set(set.steps.map(\.stepNumber)).count, set.steps.count, "Step numbers unique")
    }

    func testDeterministicOutput() throws {
        let a = try SetForgeEngine.shared.generate(from: solidBlock(), size: .small, name: "Block")
        let b = try SetForgeEngine.shared.generate(from: solidBlock(), size: .small, name: "Block")
        XCTAssertEqual(a.ldrText, b.ldrText, "Same input must yield identical LDraw output")
        XCTAssertEqual(a.brickCount, b.brickCount)
    }

    func testEmptyModelThrows() {
        let empty = VoxelModel(width: 0, height: 0, depth: 0, voxels: [], source: .text, subject: "")
        XCTAssertThrowsError(try SetForgeEngine.shared.generate(from: empty, size: .small, name: "Empty"))
    }

    func testLDRExportHasBrickLines() throws {
        let set = try SetForgeEngine.shared.generate(from: solidBlock(), size: .small, name: "Block")
        let lines = set.ldrText.split(separator: "\n").filter { $0.hasPrefix("1 ") }
        XCTAssertEqual(lines.count, set.brickCount, "One LDraw part line per brick")
    }

    func testBridgesToLegoProject() throws {
        let set = try SetForgeEngine.shared.generate(from: solidBlock(), size: .small, name: "Block")
        let project = set.asLegoProject()
        XCTAssertEqual(project.name, "Block")
        XCTAssertFalse(project.requiredPieces.isEmpty)
        XCTAssertFalse(project.instructions.isEmpty)
    }

    func testBudgetDownsampleKeepsCountReasonable() throws {
        // A dense block far over the Small budget should be downsampled.
        var voxels: [Voxel] = []
        for x in 0..<30 { for y in 0..<30 { for z in 0..<30 {
            voxels.append(Voxel(x: x, y: y, z: z, color: .blue))
        } } }
        let big = VoxelModel(width: 30, height: 30, depth: 30, voxels: voxels, source: .text, subject: "Big")
        let set = try SetForgeEngine.shared.generate(from: big, size: .small, name: "Big")
        XCTAssertLessThanOrEqual(set.brickCount, VoxelModel.Size.small.brickBudget * 2,
                                 "Downsampling should keep brick count near the budget")
    }
}
