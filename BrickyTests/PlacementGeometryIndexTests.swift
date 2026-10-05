import XCTest
import simd
@testable import Bricky

final class PlacementGeometryIndexTests: XCTestCase {
    /// A closed box, given in LDU with y up, as engine-frame triangles.
    private func box(_ minimum: SIMD3<Double>, _ maximum: SIMD3<Double>, colour: Int = 4) -> LDrawGeometryBuffer {
        let lo = SIMD3<Float>(minimum * 0.0004), hi = SIMD3<Float>(maximum * 0.0004)
        var positions: [SIMD3<Float>] = []
        func face(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>) {
            positions.append(contentsOf: [a, b, c, a, c, d])
        }
        let (x0, y0, z0, x1, y1, z1) = (lo.x, lo.y, lo.z, hi.x, hi.y, hi.z)
        face(SIMD3(x0, y1, z0), SIMD3(x1, y1, z0), SIMD3(x1, y1, z1), SIMD3(x0, y1, z1))
        face(SIMD3(x0, y0, z0), SIMD3(x0, y0, z1), SIMD3(x1, y0, z1), SIMD3(x1, y0, z0))
        face(SIMD3(x0, y0, z1), SIMD3(x0, y1, z1), SIMD3(x1, y1, z1), SIMD3(x1, y0, z1))
        face(SIMD3(x0, y0, z0), SIMD3(x1, y0, z0), SIMD3(x1, y1, z0), SIMD3(x0, y1, z0))
        face(SIMD3(x1, y0, z0), SIMD3(x1, y0, z1), SIMD3(x1, y1, z1), SIMD3(x1, y1, z0))
        face(SIMD3(x0, y0, z0), SIMD3(x0, y1, z0), SIMD3(x0, y1, z1), SIMD3(x0, y0, z1))
        return LDrawGeometryBuffer(
            colorCode: colour, positions: positions,
            normals: Array(repeating: SIMD3(0, 1, 0), count: positions.count),
            indices: positions.indices.map(UInt32.init)
        )
    }

    /// A brick of `columns` studs, body height 24 LDU plus a 4 LDU stud
    /// layer on top, its minimum corner at (x, bottom, z).
    private func brick(x: Double, z: Double, bottom: Double, columns: SIMD2<Int> = SIMD2(2, 4), height: Double = 24) -> [LDrawGeometryBuffer] {
        let width = Double(columns.x) * 20, depth = Double(columns.y) * 20
        return [
            box(SIMD3(x, bottom, z), SIMD3(x + width, bottom + height, z + depth)),
            box(SIMD3(x + 6, bottom + height, z + 6), SIMD3(x + 14, bottom + height + 4, z + 14))
        ]
    }

    private func index(_ segments: [[LDrawGeometryBuffer]], transforms: [LDrawTransform]? = nil) -> PlacementGeometryIndex {
        PlacementGeometryIndex.build(
            transforms: transforms ?? Array(repeating: LDrawTransform(), count: segments.count),
            segments: SegmentedGeometry(segments: segments)
        )
    }

    func testOnLatticeBrickHasColumnsLevelAndYaw() {
        let built = index([brick(x: 0, z: 0, bottom: 0), brick(x: 40, z: 20, bottom: 0)])
        XCTAssertEqual(built.status[0].cell, LatticeCell(minColumn: SIMD2(0, 0), footprint: SIMD2(2, 4), bottomLevel: 0, quarterTurns: 0))
        XCTAssertEqual(built.status[1].cell?.minColumn, SIMD2(2, 1))
        XCTAssertEqual(built.occupancy[SIMD2(2, 1)], [1])
    }

    func testHalfStudOffsetIsOffGrid() {
        let built = index([brick(x: 0, z: 0, bottom: 0), brick(x: 50, z: 0, bottom: 0)])
        XCTAssertEqual(built.status[1], .offLattice(.offGrid))
    }

    func testYawAndTiltClassification() {
        let quarter = LDrawTransform(a: 0, c: 1, g: -1, i: 0)
        let diagonal = LDrawTransform(a: 0.7071, c: 0.7071, g: -0.7071, i: 0.7071)
        let tilted = LDrawTransform(e: 0, f: 1, h: -1, i: 0)
        let built = index(
            [brick(x: 0, z: 0, bottom: 0), brick(x: 80, z: 0, bottom: 0), brick(x: 160, z: 0, bottom: 0), brick(x: 240, z: 0, bottom: 0)],
            transforms: [LDrawTransform(), quarter, diagonal, tilted]
        )
        XCTAssertEqual(built.status[1].cell?.quarterTurns, 1)
        XCTAssertEqual(built.status[2], .offLattice(.offAxisYaw))
        XCTAssertEqual(built.status[3], .offLattice(.tilted))
    }

    func testPlateOnBrickLevels() {
        let built = index([brick(x: 0, z: 0, bottom: 0), brick(x: 0, z: 0, bottom: 24, height: 8)])
        XCTAssertEqual(built.status[1].cell?.bottomLevel, 3, "a plate on a brick sits three plates up")
        XCTAssertEqual(built.supports[0], [1])
    }

    func testStackAndBridgeSupportGraph() {
        // 0 and 1 side by side; 2 bridges both; 3 sits on 2; 4 stands apart.
        let built = index([
            brick(x: 0, z: 0, bottom: 0, columns: SIMD2(2, 2)),
            brick(x: 40, z: 0, bottom: 0, columns: SIMD2(2, 2)),
            brick(x: 20, z: 0, bottom: 24, columns: SIMD2(2, 2)),
            brick(x: 20, z: 0, bottom: 48, columns: SIMD2(2, 2)),
            brick(x: 200, z: 0, bottom: 0, columns: SIMD2(2, 2))
        ])
        XCTAssertEqual(built.supportedBy[2], [0, 1])
        XCTAssertEqual(built.supports[2], [3])
        XCTAssertEqual(built.blockers(of: 0), [2, 3])
        XCTAssertEqual(built.blockers(of: 3), [])
        XCTAssertEqual(built.blockers(of: 4), [])
    }

    // MARK: - Symmetry

    private func symmetry(_ buffers: [LDrawGeometryBuffer]) -> RotationalSymmetry {
        RotationalSymmetry.measure(positions: buffers.flatMap(\.positions))
    }

    func testSquareIsSymmetricAtEveryQuarterTurn() {
        let square = symmetry([box(SIMD3(-20, 0, -20), SIMD3(20, 24, 20))])
        XCTAssertTrue(square.isSymmetric(quarterTurns: 1))
        XCTAssertTrue(square.isSymmetric(quarterTurns: 2))
    }

    func testOblongIsSymmetricOnlyAtAHalfTurn() {
        let oblong = symmetry([box(SIMD3(-20, 0, -40), SIMD3(20, 24, 40))])
        XCTAssertFalse(oblong.isSymmetric(quarterTurns: 1))
        XCTAssertTrue(oblong.isSymmetric(quarterTurns: 2))
    }

    func testLShapeIsNeverSymmetric() {
        let shape = symmetry([box(SIMD3(-20, 0, -20), SIMD3(20, 24, 0)), box(SIMD3(-20, 0, 0), SIMD3(0, 24, 20))])
        XCTAssertFalse(shape.isSymmetric(quarterTurns: 1))
        XCTAssertFalse(shape.isSymmetric(quarterTurns: 2))
        XCTAssertFalse(shape.isSymmetric(quarterTurns: 3))
    }

    /// A block under one half changes the part, but not what depth sees
    /// from above: the rotation is real yet invisible top-down.
    func testIdenticalFromAboveButNotFromBelow() {
        let part = symmetry([box(SIMD3(-20, 0, -40), SIMD3(20, 24, 40)), box(SIMD3(-20, -24, 0), SIMD3(20, 0, 40))])
        XCTAssertFalse(part.isSymmetric(quarterTurns: 2))
        XCTAssertTrue(part.isTopDownIdentical(quarterTurns: 2))
        XCTAssertFalse(part.isTopDownIdentical(quarterTurns: 1))
    }
}
