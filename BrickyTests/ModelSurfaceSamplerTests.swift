import XCTest
import simd
@testable import Bricky

final class ModelSurfaceSamplerTests: XCTestCase {
    /// A 10 cm × 10 cm horizontal quad (two triangles) facing +Y.
    private func quadSnapshot(colorCode: Int = 4) -> InstructionGeometrySnapshot {
        let a = SIMD3<Float>(0, 0, 0)
        let b = SIMD3<Float>(0.1, 0, 0)
        let c = SIMD3<Float>(0.1, 0, 0.1)
        let d = SIMD3<Float>(0, 0, 0.1)
        let up = SIMD3<Float>(0, 1, 0)
        let buffer = LDrawGeometryBuffer(
            colorCode: colorCode,
            positions: [a, b, c, a, c, d],
            normals: [up, up, up, up, up, up],
            indices: [0, 1, 2, 3, 4, 5]
        )
        return InstructionGeometrySnapshot(buffers: [buffer], bounds: nil)
    }

    func testSamplesQuadAtRoughlyTargetDensity() {
        let sample = ModelSurfaceSampler.sample(quadSnapshot(), stepIndex: 3)
        // 0.01 m² at one point per (3 mm)² is ~1111 before voxel dedup;
        // dedup on the same grid removes some collisions but the order of
        // magnitude must hold, or the tracker would starve.
        XCTAssertGreaterThan(sample.points.count, 400)
        XCTAssertLessThanOrEqual(sample.points.count, 1_200)
        XCTAssertEqual(sample.points.count, sample.normals.count)
        XCTAssertEqual(sample.points.count, sample.colorCodes.count)
        XCTAssertEqual(sample.stepIndex, 3)
        XCTAssertTrue(sample.normals.allSatisfy { $0 == SIMD3<Float>(0, 1, 0) })
        XCTAssertTrue(sample.colorCodes.allSatisfy { $0 == 4 })
        // Barycentric arithmetic can land a hair outside the quad in Float.
        let epsilon: Float = 1e-5
        for point in sample.points {
            XCTAssertEqual(point.y, 0)
            XCTAssertTrue((-epsilon...0.1 + epsilon).contains(point.x))
            XCTAssertTrue((-epsilon...0.1 + epsilon).contains(point.z))
        }
    }

    func testSamplingIsDeterministic() {
        let first = ModelSurfaceSampler.sample(quadSnapshot(), stepIndex: 0)
        let second = ModelSurfaceSampler.sample(quadSnapshot(), stepIndex: 0)
        XCTAssertEqual(first.points, second.points)
        XCTAssertEqual(first.normals, second.normals)
        XCTAssertEqual(first.colorCodes, second.colorCodes)
    }

    func testCapAppliesStratifiedThinning() {
        let sample = ModelSurfaceSampler.sample(quadSnapshot(), stepIndex: 0, maxPoints: 100)
        XCTAssertEqual(sample.points.count, 100)
        // The parallel arrays must stay aligned through thinning.
        XCTAssertEqual(sample.normals.count, 100)
        XCTAssertEqual(sample.colorCodes.count, 100)
        // Thinning must preserve spread: both halves of the quad stay covered.
        XCTAssertTrue(sample.points.contains { $0.x < 0.05 })
        XCTAssertTrue(sample.points.contains { $0.x > 0.05 })
    }

    func testTinyTriangleStillYieldsAPoint() {
        let up = SIMD3<Float>(0, 1, 0)
        let buffer = LDrawGeometryBuffer(
            colorCode: 1,
            positions: [.zero, SIMD3(0.001, 0, 0), SIMD3(0, 0, 0.001)],
            normals: [up, up, up],
            indices: [0, 1, 2]
        )
        let snapshot = InstructionGeometrySnapshot(buffers: [buffer], bounds: nil)
        let sample = ModelSurfaceSampler.sample(snapshot, stepIndex: 0)
        XCTAssertEqual(sample.points.count, 1)
    }

    func testEmptySnapshotYieldsEmptySample() {
        let snapshot = InstructionGeometrySnapshot(buffers: [], bounds: nil)
        let sample = ModelSurfaceSampler.sample(snapshot, stepIndex: 0)
        XCTAssertTrue(sample.points.isEmpty)
        XCTAssertTrue(sample.normals.isEmpty)
        XCTAssertTrue(sample.colorCodes.isEmpty)
    }

    func testDegenerateTriangleIsSkipped() {
        let up = SIMD3<Float>(0, 1, 0)
        let buffer = LDrawGeometryBuffer(
            colorCode: 1,
            positions: [.zero, .zero, SIMD3(0.05, 0, 0)],
            normals: [up, up, up],
            indices: [0, 1, 2]
        )
        let snapshot = InstructionGeometrySnapshot(buffers: [buffer], bounds: nil)
        XCTAssertTrue(ModelSurfaceSampler.sample(snapshot, stepIndex: 0).points.isEmpty)
    }
}
