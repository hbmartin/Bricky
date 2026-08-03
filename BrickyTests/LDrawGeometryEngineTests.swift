import Foundation
import simd
import XCTest
@testable import Bricky

final class LDrawGeometryEngineTests: XCTestCase {
    func testEmittedWorldNormalMatchesLDrawNormalMappedThroughYFlip() async throws {
        let source = try makeTemporaryFolder()
        let pack = try makeTemporaryFolder()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: pack)
        }
        try Data("""
        0 BFC CERTIFY CCW
        3 16 0 0 0 10 0 0 0 0 10
        """.utf8).write(to: source.appendingPathComponent("wedge.dat"))
        let placement = PartPlacement(
            id: "winding",
            partReference: "wedge.dat",
            colorCode: 4,
            transform: .identity,
            sourceSection: "test.ldr",
            sourceLine: 1,
            isSubmodelReference: true
        )

        let snapshot = try await LDrawGeometryEngine(sourceRoot: source, partPackRoot: pack)
            .snapshot(placements: [placement])

        // LDraw-space normal of the authored CCW triangle, mapped through the
        // engine's fixed LDraw→world reflection diag(1, −1, 1).
        let a = SIMD3<Double>(0, 0, 0)
        let b = SIMD3<Double>(10, 0, 0)
        let c = SIMD3<Double>(0, 0, 10)
        let ldrawNormal = simd_normalize(simd_cross(b - a, c - a))
        let expected = SIMD3<Float>(Float(ldrawNormal.x), Float(-ldrawNormal.y), Float(ldrawNormal.z))

        let buffer = try XCTUnwrap(snapshot.buffers.first)
        XCTAssertGreaterThan(simd_dot(simd_normalize(buffer.normals[0]), expected), 0.99)
        // The emitted vertex order must wind counter-clockwise around that
        // outward normal, or single-sided materials render inside-out.
        let winding = simd_normalize(simd_cross(
            buffer.positions[1] - buffer.positions[0],
            buffer.positions[2] - buffer.positions[0]
        ))
        XCTAssertGreaterThan(simd_dot(winding, expected), 0.99)
    }

    func testExponentialSubfileDAGHitsOperationBudgetPromptly() async throws {
        let source = try makeTemporaryFolder()
        let pack = try makeTemporaryFolder()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: pack)
        }
        try Data("3 16 0 0 0 1 0 0 0 0 1\n".utf8).write(to: source.appendingPathComponent("level0.dat"))
        for level in 1...20 {
            let line = "1 16 0 0 0 1 0 0 0 1 0 0 0 1 level\(level - 1).dat"
            try Data("\(line)\n\(line)\n".utf8).write(to: source.appendingPathComponent("level\(level).dat"))
        }
        let placement = PartPlacement(
            id: "dag",
            partReference: "level20.dat",
            colorCode: 4,
            transform: .identity,
            sourceSection: "test.ldr",
            sourceLine: 1,
            isSubmodelReference: false
        )

        // Each level references its child twice, so a full expansion performs
        // ~2^21 flatten calls; the operation budget must throw long before that.
        let engine = LDrawGeometryEngine(sourceRoot: source, partPackRoot: pack, maximumOperations: 2_000)
        let start = Date()
        do {
            _ = try await engine.snapshot(placements: [placement])
            XCTFail("Expected the geometry operation budget to trip")
        } catch let InstructionImportError.limitExceeded(message) {
            XCTAssertTrue(message.contains("subfile operations"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    func testGeometryUsesFixedScaleInheritedColorAndBounds() async throws {
        let source = try makeTemporaryFolder()
        let pack = try makeTemporaryFolder()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: pack)
        }
        try Data("""
        0 BFC CERTIFY CCW
        3 16 0 0 0 10 0 0 0 10 0
        """.utf8).write(to: source.appendingPathComponent("custom.dat"))
        let placement = PartPlacement(
            id: "test",
            partReference: "custom.dat",
            colorCode: 4,
            transform: LDrawTransform(x: 20),
            sourceSection: "test.ldr",
            sourceLine: 1,
            isSubmodelReference: true
        )

        let snapshot = try await LDrawGeometryEngine(sourceRoot: source, partPackRoot: pack)
            .snapshot(placements: [placement])

        XCTAssertEqual(snapshot.buffers.map(\.colorCode), [4])
        XCTAssertEqual(snapshot.buffers[0].positions.count, 3)
        XCTAssertEqual(snapshot.bounds?.minimum[0] ?? 0, 0.008, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.bounds?.maximum[0] ?? 0, 0.012, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.bounds?.minimum[1] ?? 0, -0.004, accuracy: 0.000_001)
    }

    func testMissingGeometryFailsInsteadOfRenderingAnIncompleteGuide() async throws {
        let source = try makeTemporaryFolder()
        let pack = try makeTemporaryFolder()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: pack)
        }
        let placement = PartPlacement(
            id: "missing",
            partReference: "missing.dat",
            colorCode: 4,
            transform: .identity,
            sourceSection: "test.ldr",
            sourceLine: 1,
            isSubmodelReference: false
        )

        do {
            _ = try await LDrawGeometryEngine(sourceRoot: source, partPackRoot: pack)
                .snapshot(placements: [placement])
            XCTFail("Expected missing geometry to fail")
        } catch let InstructionImportError.invalidDocument(message) {
            XCTAssertTrue(message.contains("missing.dat"))
        }
    }

    private func makeTemporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
