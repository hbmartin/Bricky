import XCTest
import simd
@testable import Bricky

final class MeshVoxelizerTests: XCTestCase {

    /// Build the 12 triangles of an axis-aligned box, all one color.
    private func box(
        min lo: SIMD3<Float>,
        max hi: SIMD3<Float>,
        color: SIMD3<Float>
    ) -> [MeshVoxelizer.Triangle] {
        let v = [
            SIMD3<Float>(lo.x, lo.y, lo.z), // 0
            SIMD3<Float>(hi.x, lo.y, lo.z), // 1
            SIMD3<Float>(hi.x, hi.y, lo.z), // 2
            SIMD3<Float>(lo.x, hi.y, lo.z), // 3
            SIMD3<Float>(lo.x, lo.y, hi.z), // 4
            SIMD3<Float>(hi.x, lo.y, hi.z), // 5
            SIMD3<Float>(hi.x, hi.y, hi.z), // 6
            SIMD3<Float>(lo.x, hi.y, hi.z), // 7
        ]
        let faces = [
            (0, 1, 2), (0, 2, 3), // front
            (4, 5, 6), (4, 6, 7), // back
            (0, 3, 7), (0, 7, 4), // left
            (1, 5, 6), (1, 6, 2), // right
            (0, 4, 5), (0, 5, 1), // bottom
            (3, 2, 6), (3, 6, 7), // top
        ]
        return faces.map { f in
            MeshVoxelizer.Triangle(
                p0: v[f.0], p1: v[f.1], p2: v[f.2],
                c0: color, c1: color, c2: color
            )
        }
    }

    func testSolidCubeFillsAndColors() throws {
        let red = SIMD3<Float>(0.79, 0.10, 0.04) // ~LEGO red
        let tris = box(min: .zero, max: SIMD3<Float>(1, 1, 1), color: red)
        let model = try MeshVoxelizer.voxelize(triangles: tris, size: .small, subject: "Cube")

        XCTAssertFalse(model.isEmpty)
        XCTAssertTrue(model.voxels.allSatisfy { $0.color == .red }, "Solid red cube → red bricks")

        // Solid: a centre column should span most of the height.
        let cx = model.width / 2, cz = model.depth / 2
        let columnHeights = model.voxels.filter { $0.x == cx && $0.z == cz }
        XCTAssertGreaterThan(columnHeights.count, model.height / 2,
                             "Interior column should be solidly filled")
    }

    func testCubeIsRoughlyCubic() throws {
        let tris = box(min: .zero, max: SIMD3<Float>(1, 1, 1), color: SIMD3<Float>(0, 0, 1))
        let model = try MeshVoxelizer.voxelize(triangles: tris, size: .medium, subject: "Cube")
        // Longest axis maps to maxDimension; a cube stays near-cubic.
        XCTAssertEqual(model.width, model.height, accuracy: 2)
        XCTAssertEqual(model.width, model.depth, accuracy: 2)
    }

    func testAspectRatioPreserved() throws {
        // A wide, flat box: X is longest → width == maxDimension, height small.
        let tris = box(min: .zero, max: SIMD3<Float>(4, 1, 2), color: SIMD3<Float>(1, 1, 0))
        let model = try MeshVoxelizer.voxelize(triangles: tris, size: .medium, subject: "Slab")
        XCTAssertEqual(model.width, VoxelModel.Size.medium.maxDimension, accuracy: 1)
        XCTAssertGreaterThan(model.width, model.height)
        XCTAssertGreaterThan(model.depth, model.height)
    }

    func testEmptyTrianglesThrow() {
        XCTAssertThrowsError(try MeshVoxelizer.voxelize(triangles: [], size: .small, subject: "x"))
    }

    func testVoxelizeThenForgeProducesBuildableSet() throws {
        let tris = box(min: .zero, max: SIMD3<Float>(1, 1, 1), color: SIMD3<Float>(0.1, 0.5, 0.2))
        let model = try MeshVoxelizer.voxelize(triangles: tris, size: .small, subject: "Cube")
        let set = try SetForgeEngine.shared.generate(from: model, size: .small, name: "Cube")
        XCTAssertGreaterThan(set.brickCount, 0)
        XCTAssertFalse(set.parts.isEmpty)
        XCTAssertFalse(set.steps.isEmpty)
    }
}
