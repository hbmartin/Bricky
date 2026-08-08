import XCTest
import simd
@testable import Bricky

final class ExpectedDepthRendererTests: XCTestCase {
    private let width = 256
    private let height = 192
    /// Synthetic pinhole scaled to the depth grid, ARKit convention.
    private var intrinsics: simd_float3x3 {
        var matrix = matrix_identity_float3x3
        matrix[0][0] = 200
        matrix[1][1] = 200
        matrix[2][0] = 128
        matrix[2][1] = 96
        return matrix
    }

    private func makeRenderer() throws -> ExpectedDepthRenderer {
        do {
            return try ExpectedDepthRenderer()
        } catch {
            throw XCTSkip("Metal unavailable in this test environment")
        }
    }

    /// A camera-facing square (side 0.1 m) centered on the optical axis at
    /// the given distance in front of the camera.
    private func facingQuad(distance: Float, colorCode: Int = 4) -> [LDrawGeometryBuffer] {
        let z = -distance
        let a = SIMD3<Float>(-0.05, -0.05, z)
        let b = SIMD3<Float>(0.05, -0.05, z)
        let c = SIMD3<Float>(0.05, 0.05, z)
        let d = SIMD3<Float>(-0.05, 0.05, z)
        let normal = SIMD3<Float>(0, 0, 1)
        return [LDrawGeometryBuffer(
            colorCode: colorCode,
            positions: [a, b, c, a, c, d],
            normals: Array(repeating: normal, count: 6),
            indices: [0, 1, 2, 3, 4, 5]
        )]
    }

    func testProjectsLinearDepthAtLiDARConvention() throws {
        let renderer = try makeRenderer()
        let snapshot = InstructionGeometrySnapshot(buffers: facingQuad(distance: 0.3), bounds: nil)
        let map = try renderer.render(
            snapshot: snapshot,
            viewFromModel: matrix_identity_float4x4,
            intrinsics: intrinsics,
            width: width,
            height: height
        )
        // Optical-axis pixel sees the quad at exactly its distance.
        XCTAssertEqual(map.depthAt(x: 128, y: 96), 0.3, accuracy: 0.002)
        // fx * 0.05 / 0.3 = 33.3 px half-width: inside at ±30 px, outside at ±40.
        XCTAssertEqual(map.depthAt(x: 128 + 30, y: 96), 0.3, accuracy: 0.002)
        XCTAssertEqual(map.depthAt(x: 128 + 40, y: 96), 0, "outside the quad must stay masked")
        XCTAssertEqual(map.depthAt(x: 5, y: 5), 0, "far corner must stay masked")
    }

    func testNearerGeometryOccludes() throws {
        let renderer = try makeRenderer()
        let buffers = facingQuad(distance: 0.5, colorCode: 1) + facingQuad(distance: 0.3, colorCode: 4)
        let snapshot = InstructionGeometrySnapshot(buffers: buffers, bounds: nil)
        let map = try renderer.render(
            snapshot: snapshot,
            viewFromModel: matrix_identity_float4x4,
            intrinsics: intrinsics,
            width: width,
            height: height
        )
        XCTAssertEqual(map.depthAt(x: 128, y: 96), 0.3, accuracy: 0.002)
        // The farther quad projects wider (same size, longer distance means
        // smaller, actually: half-width 200*0.05/0.5 = 20 px) — probe a pixel
        // covered only by the near quad.
        XCTAssertEqual(map.depthAt(x: 128 + 25, y: 96), 0.3, accuracy: 0.002)
    }

    func testSurfaceSelectionKeepsNearestOrFarthestOfOverlappingQuads() throws {
        // GeometricStepVerifier renders the delta with `.farthest` (the back
        // surface bounds the ray span); a regression that ignored the surface
        // parameter would silently judge absence against the wrong depth.
        let renderer = try makeRenderer()
        let snapshot = InstructionGeometrySnapshot(
            buffers: facingQuad(distance: 0.5, colorCode: 1) + facingQuad(distance: 0.3, colorCode: 4),
            bounds: nil
        )
        let nearest = try renderer.render(
            snapshot: snapshot,
            viewFromModel: matrix_identity_float4x4,
            intrinsics: intrinsics,
            width: width,
            height: height,
            surface: .nearest
        )
        let farthest = try renderer.render(
            snapshot: snapshot,
            viewFromModel: matrix_identity_float4x4,
            intrinsics: intrinsics,
            width: width,
            height: height,
            surface: .farthest
        )
        XCTAssertEqual(nearest.depthAt(x: 128, y: 96), 0.3, accuracy: 0.002)
        XCTAssertEqual(farthest.depthAt(x: 128, y: 96), 0.5, accuracy: 0.002)
    }

    func testViewFromModelTransformApplies() throws {
        let renderer = try makeRenderer()
        // Model authored at the origin; the transform pushes it 0.4 m ahead.
        let z = SIMD3<Float>(0, 0, 1)
        let quad = [LDrawGeometryBuffer(
            colorCode: 4,
            positions: [
                SIMD3(-0.05, -0.05, 0), SIMD3(0.05, -0.05, 0), SIMD3(0.05, 0.05, 0),
                SIMD3(-0.05, -0.05, 0), SIMD3(0.05, 0.05, 0), SIMD3(-0.05, 0.05, 0)
            ],
            normals: Array(repeating: z, count: 6),
            indices: [0, 1, 2, 3, 4, 5]
        )]
        var viewFromModel = matrix_identity_float4x4
        viewFromModel.columns.3 = SIMD4(0, 0, -0.4, 1)
        let map = try renderer.render(
            snapshot: InstructionGeometrySnapshot(buffers: quad, bounds: nil),
            viewFromModel: viewFromModel,
            intrinsics: intrinsics,
            width: width,
            height: height
        )
        XCTAssertEqual(map.depthAt(x: 128, y: 96), 0.4, accuracy: 0.002)
    }

    func testEmptySnapshotRendersAllMasked() throws {
        let renderer = try makeRenderer()
        let map = try renderer.render(
            snapshot: InstructionGeometrySnapshot(buffers: [], bounds: nil),
            viewFromModel: matrix_identity_float4x4,
            intrinsics: intrinsics,
            width: width,
            height: height
        )
        XCTAssertTrue(map.depth.allSatisfy { $0 == 0 })
    }

    func testGeometryBehindCameraRendersAllMasked() throws {
        let renderer = try makeRenderer()
        let map = try renderer.render(
            snapshot: InstructionGeometrySnapshot(buffers: facingQuad(distance: -0.3), bounds: nil),
            viewFromModel: matrix_identity_float4x4,
            intrinsics: intrinsics,
            width: width,
            height: height
        )
        XCTAssertEqual(map.depthAt(x: 128, y: 96), 0)
        XCTAssertTrue(map.depth.allSatisfy { !$0.isNaN && $0 == 0 })
    }

    func testGeometryBeyondFarPlaneStaysMasked() throws {
        let renderer = try makeRenderer()
        let map = try renderer.render(
            snapshot: InstructionGeometrySnapshot(buffers: facingQuad(distance: 8.0), bounds: nil),
            viewFromModel: matrix_identity_float4x4,
            intrinsics: intrinsics,
            width: width,
            height: height,
            far: 5.0
        )
        XCTAssertEqual(map.depthAt(x: 128, y: 96), 0)
        XCTAssertTrue(map.depth.allSatisfy { !$0.isNaN && $0 == 0 })
    }
}
