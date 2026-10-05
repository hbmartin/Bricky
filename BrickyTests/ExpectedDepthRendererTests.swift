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

    // MARK: - Shared instance, prepared geometry, and batches

    private func request(
        _ geometry: DepthGeometry,
        distanceOffset: Float = 0,
        surface: ExpectedDepthRenderer.Surface = .nearest
    ) -> DepthRenderRequest {
        var viewFromModel = matrix_identity_float4x4
        viewFromModel.columns.3 = SIMD4(0.01, -0.005, -distanceOffset, 1)
        return DepthRenderRequest(geometry: geometry, viewFromModel: viewFromModel, surface: surface)
    }

    /// Two overlapping quads, so the nearest and farthest surfaces differ.
    private var layeredSnapshot: InstructionGeometrySnapshot {
        InstructionGeometrySnapshot(buffers: facingQuad(distance: 0.3) + facingQuad(distance: 0.35), bounds: nil)
    }

    func testBatchIsBitIdenticalToSingleRenders() async throws {
        let renderer = try makeRenderer()
        let geometry = renderer.prepare(layeredSnapshot)
        let requests = [
            request(geometry),
            request(geometry, surface: .farthest),
            request(geometry, distanceOffset: 0.1),
            request(renderer.prepare(InstructionGeometrySnapshot(buffers: [], bounds: nil)))
        ]
        let batch = try await renderer.render(requests, intrinsics: intrinsics, width: width, height: height)
        XCTAssertEqual(batch.count, requests.count)
        let snapshots = [layeredSnapshot, layeredSnapshot, layeredSnapshot, InstructionGeometrySnapshot(buffers: [], bounds: nil)]
        for (index, (single, snapshot)) in zip(requests, snapshots).enumerated() {
            let alone = try renderer.render(
                snapshot: snapshot,
                viewFromModel: single.viewFromModel,
                intrinsics: intrinsics,
                width: width,
                height: height,
                surface: single.surface
            )
            XCTAssertEqual(batch[index].depth, alone.depth, "request \(index) differs from its single render")
        }
        XCTAssertGreaterThan(batch[1].depthAt(x: 128, y: 96), batch[0].depthAt(x: 128, y: 96), "farthest must see the back quad")
        XCTAssertTrue(batch[3].depth.allSatisfy { $0 == 0 }, "empty geometry clears its target")
    }

    func testTargetsAreReusedAcrossBatches() async throws {
        // Reused pool targets must be cleared: a second batch drawing nothing
        // must not see the first batch's depth.
        let renderer = try makeRenderer()
        _ = try await renderer.render([request(renderer.prepare(layeredSnapshot))], intrinsics: intrinsics, width: width, height: height)
        let empty = renderer.prepare(InstructionGeometrySnapshot(buffers: [], bounds: nil))
        let maps = try await renderer.render([request(empty)], intrinsics: intrinsics, width: width, height: height)
        XCTAssertTrue(maps[0].depth.allSatisfy { $0 == 0 })
    }

    func testConcurrentBatchesDoNotInterfere() async throws {
        let renderer = try makeRenderer()
        let near = renderer.prepare(InstructionGeometrySnapshot(buffers: facingQuad(distance: 0.3), bounds: nil))
        let far = renderer.prepare(InstructionGeometrySnapshot(buffers: facingQuad(distance: 0.6), bounds: nil))
        let intrinsics = intrinsics, width = width, height = height
        let depths = try await withThrowingTaskGroup(of: (Int, Float).self) { group in
            for index in 0..<8 {
                let geometry = index.isMultiple(of: 2) ? near : far
                group.addTask {
                    let maps = try await renderer.render(
                        [DepthRenderRequest(geometry: geometry, viewFromModel: matrix_identity_float4x4)],
                        intrinsics: intrinsics, width: width, height: height
                    )
                    return (index, maps[0].depthAt(x: 128, y: 96))
                }
            }
            var results: [Int: Float] = [:]
            for try await (index, depth) in group { results[index] = depth }
            return results
        }
        for (index, depth) in depths {
            XCTAssertEqual(depth, index.isMultiple(of: 2) ? 0.3 : 0.6, accuracy: 0.002, "batch \(index)")
        }
    }

    // MARK: - Range draws (M2.0)

    /// Three placements: quads at different depths and positions, one
    /// overlapping another, each its own segment.
    private var segments: SegmentedGeometry {
        func quad(x: Float, distance: Float, colour: Int) -> LDrawGeometryBuffer {
            let z = -distance
            let a = SIMD3<Float>(x - 0.03, -0.03, z), b = SIMD3<Float>(x + 0.03, -0.03, z)
            let c = SIMD3<Float>(x + 0.03, 0.03, z), d = SIMD3<Float>(x - 0.03, 0.03, z)
            return LDrawGeometryBuffer(
                colorCode: colour, positions: [a, b, c, a, c, d],
                normals: Array(repeating: SIMD3(0, 0, 1), count: 6), indices: [0, 1, 2, 3, 4, 5]
            )
        }
        return SegmentedGeometry(segments: [
            [quad(x: -0.05, distance: 0.3, colour: 4)],
            [quad(x: 0.0, distance: 0.4, colour: 1)],
            [quad(x: 0.02, distance: 0.35, colour: 4)]
        ])
    }

    private func render(_ renderer: ExpectedDepthRenderer, _ requests: [DepthRenderRequest]) async throws -> [ExpectedDepthMap] {
        try await renderer.render(requests, intrinsics: intrinsics, width: width, height: height)
    }

    func testNilRangesMatchWholeDraw() async throws {
        let renderer = try makeRenderer()
        let geometry = renderer.prepare(segments)
        let whole = try await render(renderer, [DepthRenderRequest(geometry: geometry, viewFromModel: matrix_identity_float4x4)])
        let ranged = try await render(renderer, [DepthRenderRequest(
            geometry: geometry, viewFromModel: matrix_identity_float4x4, ranges: [0..<geometry.vertexCount]
        )])
        XCTAssertEqual(whole[0].depth, ranged[0].depth)
        let none = try await render(renderer, [DepthRenderRequest(geometry: geometry, viewFromModel: matrix_identity_float4x4, ranges: [])])
        XCTAssertTrue(none[0].depth.allSatisfy { $0 == 0 }, "an empty range list draws nothing")
    }

    func testRangeMatchesSubsetSnapshot() async throws {
        let renderer = try makeRenderer()
        let segments = segments
        let ranged = try await render(renderer, [DepthRenderRequest(
            geometry: renderer.prepare(segments), viewFromModel: matrix_identity_float4x4,
            ranges: [segments.vertexRange(1)]
        )])
        let subset = try renderer.render(
            snapshot: segments.mergedByColour(1..<2), viewFromModel: matrix_identity_float4x4,
            intrinsics: intrinsics, width: width, height: height
        )
        XCTAssertEqual(ranged[0].depth, subset.depth)
    }

    func testExcludingRangesMatchConcatenation() async throws {
        let renderer = try makeRenderer()
        let segments = segments
        let excluded = try await render(renderer, [DepthRenderRequest(
            geometry: renderer.prepare(segments), viewFromModel: matrix_identity_float4x4,
            ranges: segments.vertexRanges(0..<3, excluding: 1)
        )])
        let others = InstructionGeometrySnapshot(
            buffers: segments.mergedByColour(0..<1).buffers + segments.mergedByColour(2..<3).buffers, bounds: nil
        )
        let concatenated = try renderer.render(
            snapshot: others, viewFromModel: matrix_identity_float4x4, intrinsics: intrinsics, width: width, height: height
        )
        XCTAssertEqual(excluded[0].depth, concatenated.depth)
    }

    func testOutOfBoundsRangeFails() async throws {
        let renderer = try makeRenderer()
        let geometry = renderer.prepare(segments)
        do {
            _ = try await render(renderer, [DepthRenderRequest(
                geometry: geometry, viewFromModel: matrix_identity_float4x4, ranges: [0..<(geometry.vertexCount + 3)]
            )])
            XCTFail("a range past the vertex buffer must fail")
        } catch {}
    }

    func testBatchWithRangesBitIdenticalToSingles() async throws {
        let renderer = try makeRenderer()
        let segments = segments
        let geometry = renderer.prepare(segments)
        let requests = [
            DepthRenderRequest(geometry: geometry, viewFromModel: matrix_identity_float4x4, ranges: [segments.vertexRange(0)]),
            DepthRenderRequest(geometry: geometry, viewFromModel: matrix_identity_float4x4, surface: .farthest),
            DepthRenderRequest(geometry: geometry, viewFromModel: matrix_identity_float4x4, ranges: segments.vertexRanges(0..<3, excluding: 2))
        ]
        let batch = try await render(renderer, requests)
        for (index, request) in requests.enumerated() {
            let single = try await render(renderer, [request])
            XCTAssertEqual(batch[index].depth, single[0].depth, "request \(index)")
        }
    }

    /// Empirical, not a guarantee: on geometry without exact depth ties
    /// between differently coloured triangles, timeline order and colour
    /// order rasterize identically. Existing consumers keep colour order.
    func testTimelineOrderMatchesColourOrderOnFixtures() async throws {
        let renderer = try makeRenderer()
        let segments = segments
        let timeline = try await render(renderer, [DepthRenderRequest(geometry: renderer.prepare(segments), viewFromModel: matrix_identity_float4x4)])
        let colour = try renderer.render(
            snapshot: segments.mergedByColour(prefix: 3), viewFromModel: matrix_identity_float4x4,
            intrinsics: intrinsics, width: width, height: height
        )
        XCTAssertEqual(timeline[0].depth, colour.depth)
    }

    func testSharedRendererIsOneInstance() throws {
        do {
            let first = try ExpectedDepthRenderer.shared()
            let second = try ExpectedDepthRenderer.shared()
            XCTAssertTrue(first === second)
        } catch {
            throw XCTSkip("Metal unavailable in this test environment")
        }
    }
}
