import Foundation
import XCTest
@testable import Bricky

final class LDrawGeometryEngineTests: XCTestCase {
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
