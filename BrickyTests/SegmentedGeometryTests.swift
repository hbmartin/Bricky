import XCTest
import simd
@testable import Bricky

/// One segmented flatten must reproduce the engine's colour-merged snapshot
/// of any placement range bit for bit: the surface sampler and the verifier
/// were tuned on that exact buffer layout.
final class SegmentedGeometryTests: XCTestCase {
    private var source: URL!
    private var pack: URL!

    override func setUpWithError() throws {
        source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        pack = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        // A part mixing inherited (16) and edge (24) colours, a quad, and an
        // inverted subfile; a direct-colour part; and a submodel.
        try write("box.dat", """
        0 BFC CERTIFY CCW
        3 16 0 0 0 20 0 0 0 0 20
        4 24 0 -8 0 20 -8 0 20 -8 20 0 -8 20
        0 BFC INVERTNEXT
        1 16 0 0 0 1 0 0 0 1 0 0 0 1 face.dat
        """)
        try write("face.dat", "3 16 0 0 0 0 0 20 20 0 0\n")
        try write("red.dat", "3 4 0 0 0 10 0 0 0 10 0\n")
        try write("sub.ldr", "1 14 0 -24 0 1 0 0 0 1 0 0 0 1 box.dat\n1 16 40 0 0 1 0 0 0 1 0 0 0 1 red.dat\n")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: source)
        try? FileManager.default.removeItem(at: pack)
    }

    private func write(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: source.appendingPathComponent(name))
    }

    private func placement(_ id: Int, _ part: String, colour: Int, _ transform: LDrawTransform) -> PartPlacement {
        PartPlacement(
            id: "p\(id)", partReference: part, colorCode: colour, transform: transform,
            sourceSection: "main.ldr", sourceLine: id, isSubmodelReference: part.hasSuffix(".ldr")
        )
    }

    private var placements: [PartPlacement] {
        [
            placement(0, "box.dat", colour: 1, LDrawTransform()),
            placement(1, "red.dat", colour: 16, LDrawTransform(x: 20)),
            // Mirrored: flips the winding decision.
            placement(2, "box.dat", colour: 2, LDrawTransform(x: 60, a: -1)),
            placement(3, "box.dat", colour: 1, LDrawTransform(y: -24)),
            placement(4, "sub.ldr", colour: 2, LDrawTransform(z: 40))
        ]
    }

    private func engine(maximumTriangles: Int = InstructionLimits.maximumGeometryTriangles) -> LDrawGeometryEngine {
        LDrawGeometryEngine(sourceRoot: source, partPackRoot: pack, maximumTriangles: maximumTriangles)
    }

    private func assertBitIdentical(
        _ actual: InstructionGeometrySnapshot, _ expected: InstructionGeometrySnapshot,
        _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        func bits(_ values: [SIMD3<Float>]) -> [UInt32] { values.flatMap { [$0.x.bitPattern, $0.y.bitPattern, $0.z.bitPattern] } }
        XCTAssertEqual(actual.buffers.map(\.colorCode), expected.buffers.map(\.colorCode), message, file: file, line: line)
        for (a, e) in zip(actual.buffers, expected.buffers) {
            XCTAssertEqual(bits(a.positions), bits(e.positions), "\(message) positions", file: file, line: line)
            XCTAssertEqual(bits(a.normals), bits(e.normals), "\(message) normals", file: file, line: line)
            XCTAssertEqual(a.indices, e.indices, "\(message) indices", file: file, line: line)
        }
        XCTAssertEqual(
            actual.bounds.map { ($0.minimum + $0.maximum).map(\.bitPattern) },
            expected.bounds.map { ($0.minimum + $0.maximum).map(\.bitPattern) },
            "\(message) bounds", file: file, line: line
        )
    }

    func testMergedPrefixBitIdenticalForEveryStep() async throws {
        let engine = engine()
        let segmented = try await engine.segmented(placements: placements)
        XCTAssertEqual(segmented.placementCount, placements.count)
        for count in 0...placements.count {
            let legacy = try await engine.snapshot(placements: placements.prefix(count))
            assertBitIdentical(segmented.mergedByColour(prefix: count), legacy, "prefix \(count)")
        }
    }

    func testMergedSubrangeMatchesDelta() async throws {
        let engine = engine()
        let segmented = try await engine.segmented(placements: placements)
        let legacy = try await engine.snapshot(placements: placements[2..<4])
        assertBitIdentical(segmented.mergedByColour(2..<4), legacy, "delta 2..<4")
    }

    func testSamplerIdenticalOnMergedPrefix() async throws {
        let engine = engine()
        let segmented = try await engine.segmented(placements: placements)
        let legacy = ModelSurfaceSampler.sample(try await engine.snapshot(placements: placements.prefix(4)), stepIndex: 3)
        let merged = ModelSurfaceSampler.sample(segmented.mergedByColour(prefix: 4), stepIndex: 3)
        XCTAssertEqual(merged.points, legacy.points)
        XCTAssertEqual(merged.normals, legacy.normals)
        XCTAssertEqual(merged.colorCodes, legacy.colorCodes)
    }

    func testBudgetsThrowAtTheSameSize() async throws {
        let full = try await engine().segmented(placements: placements)
        let triangles = full.vertexCount / 3
        let tight = engine(maximumTriangles: triangles - 1)
        do {
            _ = try await tight.segmented(placements: placements)
            XCTFail("one triangle over the budget must fail")
        } catch {}
        do {
            _ = try await tight.snapshot(placements: placements)
            XCTFail("the legacy path fails at the same size")
        } catch {}
        _ = try await engine(maximumTriangles: triangles).segmented(placements: placements)
    }

    func testExcludingSplitsAroundPlacement() async throws {
        let segmented = try await engine().segmented(placements: placements)
        let all = segmented.vertexRange(0..<5)
        let excluded = segmented.vertexRange(2)
        let ranges = segmented.vertexRanges(0..<5, excluding: 2)
        XCTAssertEqual(ranges, [all.lowerBound..<excluded.lowerBound, excluded.upperBound..<all.upperBound])
        XCTAssertEqual(segmented.vertexRanges(0..<5, excluding: 0), [segmented.vertexRange(1..<5)])
        XCTAssertEqual(segmented.vertexRanges(0..<2, excluding: 4), [segmented.vertexRange(0..<2)])
        XCTAssertTrue(segmented.vertexRange(9..<12).isEmpty, "out of range is empty, not a trap")
    }
}
