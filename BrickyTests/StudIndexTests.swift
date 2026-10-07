import Foundation
import simd
import XCTest
@testable import Bricky

/// Stud identity survives the flatten (Phase 4): which primitive each stud
/// is, where its top sits, and which triangles it drew, without changing a
/// single triangle of the geometry.
final class StudIndexTests: XCTestCase {
    private var source: URL!
    private var pack: URL!

    override func setUpWithError() throws {
        source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        pack = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        for directory in [source!, pack.appendingPathComponent("p"), pack.appendingPathComponent("parts")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        func write(_ text: String, _ path: String) throws {
            try Data(text.utf8).write(to: pack.appendingPathComponent(path))
        }
        // A stud: its top face 4 LDU above its base, and one side face.
        try write("""
        0 Stud
        4 16 -6 -4 -6 6 -4 -6 6 -4 6 -6 -4 6
        4 16 -6 0 -6 6 0 -6 6 -4 -6 -6 -4 -6
        """, "p/stud.dat")
        try write("""
        0 Stud Tube Open
        3 16 -8 0 0 8 0 0 0 4 8
        """, "p/stud4.dat")
        try write("""
        0 Stud Group  2 x  1
        1 16 10 0 0 1 0 0 0 1 0 0 0 1 stud.dat
        1 16 -10 0 0 1 0 0 0 1 0 0 0 1 stud.dat
        """, "p/stug-2x1.dat")
        // A brick: its top face, two grouped studs, a tube underneath, and
        // one stud drawn at twice the size.
        try write("""
        0 Test Brick
        4 16 -20 0 -10 20 0 -10 20 0 10 -20 0 10
        1 16 0 0 0 1 0 0 0 1 0 0 0 1 stug-2x1.dat
        1 16 0 24 0 1 0 0 0 1 0 0 0 1 stud4.dat
        1 16 0 0 20 2 0 0 0 2 0 0 0 2 stud.dat
        """, "parts/brick.dat")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: source)
        try? FileManager.default.removeItem(at: pack)
    }

    private var placements: [PartPlacement] {
        [
            PartPlacement(id: "p0", partReference: "brick.dat", colorCode: 4, transform: .identity,
                          sourceSection: "m.ldr", sourceLine: 1, isSubmodelReference: false),
            PartPlacement(id: "p1", partReference: "brick.dat", colorCode: 1, transform: LDrawTransform(x: 40, y: -24),
                          sourceSection: "m.ldr", sourceLine: 2, isSubmodelReference: false),
        ]
    }

    private func index() async throws -> (SegmentedGeometry, StudIndex) {
        try await LDrawGeometryEngine(sourceRoot: source, partPackRoot: pack).segmentedWithStuds(placements: placements)
    }

    func testStudIdentitySurvivesFlatten() async throws {
        let (geometry, studs) = try await index()
        XCTAssertEqual(studs.studs.count, 8, "two grouped studs, a tube and a scaled stud per brick")
        XCTAssertEqual(studs.studs.map(\.placement), [0, 0, 0, 0, 1, 1, 1, 1])
        XCTAssertEqual(studs.triangleStud.count, geometry.triangleColours.count)
        // Every stud drew its own triangles, and the brick's top face is no
        // stud's.
        for ordinal in 1...UInt32(studs.studs.count) {
            XCTAssertTrue(studs.triangleStud.contains(ordinal), "stud \(ordinal) drew nothing")
        }
        XCTAssertEqual(studs.triangleStud[geometry.placementTriangleStarts[0]], 0)
        XCTAssertEqual(studs.studs.map(\.colourCode), [4, 4, 4, 4, 1, 1, 1, 1], "a stud takes its brick's colour")
    }

    func testGroupedStudsResolveToLeaves() async throws {
        let (_, studs) = try await index()
        let first = studs.studs(in: 0..<1)
        XCTAssertEqual(first.map(\.primitive), ["stud.dat", "stud.dat", "stud4.dat", "stud.dat"])
    }

    func testUndersideTubesNotTop() async throws {
        let (_, studs) = try await index()
        XCTAssertEqual(studs.studs.filter { $0.role == .underside }.map(\.primitive), ["stud4.dat", "stud4.dat"])
        XCTAssertEqual(studs.topStuds.count, 6)
    }

    func testTopCentreFollowsYFlip() async throws {
        let (_, studs) = try await index()
        let stud = studs.studs[0]
        // At LDraw (10, -4, 0): world metres flip Y.
        XCTAssertEqual(stud.keypoint.x, 0.004, accuracy: 1e-7)
        XCTAssertEqual(stud.keypoint.y, 0.0016, accuracy: 1e-7)
        XCTAssertEqual(stud.keypoint.z, 0, accuracy: 1e-7)
        XCTAssertEqual(stud.axis, SIMD3(0, 1, 0))
        // The second brick sits 40 LDU along x and one brick higher.
        let moved = studs.studs[4]
        XCTAssertEqual(moved.keypoint.x, 0.02, accuracy: 1e-7)
        XCTAssertEqual(moved.keypoint.y, 0.0016 + 0.0096, accuracy: 1e-7)
    }

    func testScaledStudFlagged() async throws {
        let (_, studs) = try await index()
        let scaled = studs.studs[3]
        XCTAssertEqual(scaled.scale, 2, accuracy: 1e-5)
        XCTAssertTrue(scaled.isScaled)
        XCTAssertFalse(studs.studs[0].isScaled)
        // Its top face is 8 LDU up at twice the size.
        XCTAssertEqual(scaled.keypoint.y, 0.0032, accuracy: 1e-7)
    }

    func testSegmentedBitIdenticalWithCollector() async throws {
        let engine = LDrawGeometryEngine(sourceRoot: source, partPackRoot: pack)
        let plain = try await engine.segmented(placements: placements)
        let (collected, _) = try await engine.segmentedWithStuds(placements: placements)
        XCTAssertEqual(plain.positions.map(\.x.bitPattern), collected.positions.map(\.x.bitPattern))
        XCTAssertEqual(plain.positions.map(\.y.bitPattern), collected.positions.map(\.y.bitPattern))
        XCTAssertEqual(plain.positions.map(\.z.bitPattern), collected.positions.map(\.z.bitPattern))
        XCTAssertEqual(plain.normals, collected.normals)
        XCTAssertEqual(plain.triangleColours, collected.triangleColours)
        XCTAssertEqual(plain.placementTriangleStarts, collected.placementTriangleStarts)
        // And the collector leaves no state behind for the next plain call.
        let again = try await engine.segmented(placements: placements)
        XCTAssertEqual(again.positions, plain.positions)
    }

    func testProjectionMatchesTheShaderConvention() throws {
        var intrinsics = matrix_identity_float3x3
        intrinsics[0][0] = 210
        intrinsics[1][1] = 210
        intrinsics[2][0] = 128
        intrinsics[2][1] = 96
        // The camera at the origin looks down −Z, +Y up, image y down.
        let projected = try XCTUnwrap(StudProjection.project(
            SIMD3(0.1, 0.05, -1), viewFromModel: matrix_identity_float4x4, intrinsics: intrinsics
        ))
        XCTAssertEqual(projected.u, 149, accuracy: 1e-4)
        XCTAssertEqual(projected.v, 85.5, accuracy: 1e-4)
        XCTAssertEqual(projected.depth, 1, accuracy: 1e-6)
        XCTAssertNil(StudProjection.project(SIMD3(0, 0, 1), viewFromModel: matrix_identity_float4x4, intrinsics: intrinsics))
    }

    func testVisibilityNeedsTheIDNearbyEnoughPixelsAndAgreeingDepth() {
        let index = StudIndex(studs: [
            StudInstance(placement: 0, primitive: "stud.dat", role: .top, keypoint: SIMD3(0, 0, -1),
                         axis: SIMD3(0, 0, 1), scale: 1, colourCode: 4),
            StudInstance(placement: 0, primitive: "stud.dat", role: .top, keypoint: SIMD3(0.01, 0, -1),
                         axis: SIMD3(0, 0, -1), scale: 1, colourCode: 4),
        ], triangleStud: [])
        var intrinsics = matrix_identity_float3x3
        intrinsics[0][0] = 100
        intrinsics[1][1] = 100
        intrinsics[2][0] = 4
        intrinsics[2][1] = 4
        // An 8×8 view: stud 1 owns a 3×3 patch round the centre at its own
        // depth; stud 2's keypoint (one pixel right) shows stud 1, so it is
        // hidden.
        var ids = [UInt32](repeating: 0, count: 64)
        var depth = [Float32](repeating: 0, count: 64)
        for y in 3...5 {
            for x in 3...5 {
                ids[y * 8 + x] = 1
                depth[y * 8 + x] = 1
            }
        }
        let labels = StudVisibility.labels(
            index: index, studs: [0, 1], viewFromModel: matrix_identity_float4x4, intrinsics: intrinsics,
            ids: ids, depth: depth, width: 8, height: 8
        )
        XCTAssertEqual(labels.map(\.visible), [true, false])
        XCTAssertEqual(labels.map(\.pixels), [9, 0])
        XCTAssertEqual(labels.map(\.upFacing), [true, false], "only the first stud's axis points at the camera")
        // The same id with the wrong depth is a stud seen through something.
        depth = depth.map { $0 > 0 ? 0.9 : 0 }
        let behind = StudVisibility.labels(
            index: index, studs: [0], viewFromModel: matrix_identity_float4x4, intrinsics: intrinsics,
            ids: ids, depth: depth, width: 8, height: 8
        )
        XCTAssertEqual(behind.first?.visible, false)
    }

    func testCatalogClassifiesKnownNames() {
        XCTAssertEqual(StudPrimitiveCatalog.kind(of: "stud.dat"), .stud(.top))
        XCTAssertEqual(StudPrimitiveCatalog.kind(of: "8/stud.dat"), .stud(.top))
        XCTAssertEqual(StudPrimitiveCatalog.kind(of: "p\\48\\stud2.dat"), .stud(.top))
        XCTAssertEqual(StudPrimitiveCatalog.kind(of: "stud-logo4.dat"), .stud(.top))
        XCTAssertEqual(StudPrimitiveCatalog.kind(of: "stud4f1n.dat"), .stud(.underside))
        XCTAssertEqual(StudPrimitiveCatalog.kind(of: "stud12.dat"), .stud(.underside))
        XCTAssertEqual(StudPrimitiveCatalog.kind(of: "stug-2x2.dat"), .group)
        XCTAssertEqual(StudPrimitiveCatalog.kind(of: "stu2.dat"), .moved)
        XCTAssertEqual(StudPrimitiveCatalog.kind(of: "studline.dat"), .excluded)
        XCTAssertNil(StudPrimitiveCatalog.kind(of: "3001.dat"))
        XCTAssertNil(StudPrimitiveCatalog.kind(of: "stud99.dat"), "an unknown stud is not guessed at")
    }
}
