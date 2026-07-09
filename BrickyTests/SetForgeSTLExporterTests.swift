import XCTest
@testable import Bricky

final class SetForgeSTLExporterTests: XCTestCase {

    private func brick(_ x: Int, _ y: Int, _ z: Int, length: Int = 1) -> PlacedBrick {
        PlacedBrick(x: x, y: y, z: z, length: length, color: .red)
    }

    func testHeaderAndTriangleCount() {
        let bricks = [brick(0, 0, 0), brick(1, 0, 0, length: 2)]
        let data = SetForgeSTLExporter.export(bricks)

        // 80-byte header + 4-byte count + 50 bytes per triangle.
        XCTAssertGreaterThan(data.count, 84)
        let triCount = data.subdata(in: 80..<84).withUnsafeBytes {
            $0.load(as: UInt32.self).littleEndian
        }
        XCTAssertEqual(Int(triCount), bricks.count * 12, "12 triangles per brick box")
        XCTAssertEqual(data.count, 84 + Int(triCount) * 50, "Binary STL size is exact")
    }

    func testEmptyBricksYieldsValidEmptySTL() {
        let data = SetForgeSTLExporter.export([])
        XCTAssertEqual(data.count, 84, "Header + zero-count only")
        let triCount = data.subdata(in: 80..<84).withUnsafeBytes {
            $0.load(as: UInt32.self).littleEndian
        }
        XCTAssertEqual(triCount, 0)
    }

    func testDeterministic() {
        let bricks = [brick(0, 0, 0), brick(0, 1, 0), brick(2, 0, 3, length: 4)]
        XCTAssertEqual(SetForgeSTLExporter.export(bricks), SetForgeSTLExporter.export(bricks))
    }

    func testScalesToRealWorldMillimetres() {
        // A single 1x1 brick spans one stud (8mm) x one layer (9.6mm) x one stud.
        let data = SetForgeSTLExporter.export([brick(0, 0, 0)])
        XCTAssertEqual(data.count, 84 + 12 * 50)
    }
}
