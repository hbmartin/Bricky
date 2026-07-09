import XCTest
@testable import Bricky

final class VoxelPackerTests: XCTestCase {

    func testSplitRunNoStaggerGreedyLongestFirst() {
        XCTAssertEqual(VoxelPacker.splitRun(8, stagger: false), [8])
        XCTAssertEqual(VoxelPacker.splitRun(10, stagger: false), [8, 2])
        XCTAssertEqual(VoxelPacker.splitRun(5, stagger: false), [4, 1])
        XCTAssertEqual(VoxelPacker.splitRun(1, stagger: false), [1])
        XCTAssertEqual(VoxelPacker.splitRun(0, stagger: false), [])
    }

    func testSplitRunStaggerLeadsWithSingle() {
        let pieces = VoxelPacker.splitRun(8, stagger: true)
        XCTAssertEqual(pieces.first, 1, "Staggered runs lead with a 1-stud brick to offset seams")
        XCTAssertEqual(pieces.reduce(0, +), 8, "Staggered split still covers the full run")
    }

    func testSplitRunSumsToLength() {
        for length in 1...40 {
            XCTAssertEqual(VoxelPacker.splitRun(length, stagger: false).reduce(0, +), length)
            XCTAssertEqual(VoxelPacker.splitRun(length, stagger: true).reduce(0, +), length)
        }
    }

    func testPackCoversEveryVoxelExactlyOnce() {
        var voxels: [Voxel] = []
        for x in 0..<7 { for z in 0..<3 {
            voxels.append(Voxel(x: x, y: 0, z: z, color: .green))
        } }
        let model = VoxelModel(width: 7, height: 1, depth: 3, voxels: voxels, source: .text, subject: "Slab")
        let bricks = VoxelPacker.pack(model)
        let studTotal = bricks.reduce(0) { $0 + $1.length }
        XCTAssertEqual(studTotal, voxels.count, "Bricks must cover every voxel exactly once")
    }

    func testPackEmptyModelYieldsNoBricks() {
        let empty = VoxelModel(width: 0, height: 0, depth: 0, voxels: [], source: .text, subject: "")
        XCTAssertTrue(VoxelPacker.pack(empty).isEmpty)
    }

    func testPackSeparatesColorsIntoDistinctRuns() {
        let voxels = [
            Voxel(x: 0, y: 0, z: 0, color: .red),
            Voxel(x: 1, y: 0, z: 0, color: .red),
            Voxel(x: 2, y: 0, z: 0, color: .blue),
        ]
        let model = VoxelModel(width: 3, height: 1, depth: 1, voxels: voxels, source: .text, subject: "Two")
        let bricks = VoxelPacker.pack(model)
        XCTAssertEqual(bricks.count, 2)
        XCTAssertTrue(bricks.contains { $0.length == 2 && $0.color == .red })
        XCTAssertTrue(bricks.contains { $0.length == 1 && $0.color == .blue })
    }
}
