import CryptoKit
import Foundation
import XCTest
@testable import Bricky

final class InstructionImporterTests: XCTestCase {
    func testFolderImportFindsRootCopiesCompleteClosureAndBuildsGuide() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("""
        1 4 100 0 0 1 0 0 0 1 0 0 0 1 child.ldr
        0 STEP
        """.utf8).write(to: folder.appendingPathComponent("main.ldr"))
        try Data("""
        1 16 20 0 0 1 0 0 0 1 0 0 0 1 custom.dat
        0 STEP
        """.utf8).write(to: folder.appendingPathComponent("child.ldr"))
        try Data("3 16 0 0 0 10 0 0 0 10 0\n".utf8).write(to: folder.appendingPathComponent("custom.dat"))

        let plan = try await InstructionModelImporter().import(source: .folder(folder))
        XCTAssertEqual(plan.sourceFilename, "main.ldr")
        XCTAssertEqual(plan.steps.count, 2)
        XCTAssertEqual(plan.placementTimeline.first?.partReference, "custom.dat")
        XCTAssertEqual(plan.placementTimeline.first?.transform.x, 120)

        let importedRoot = try InstructionModelImporter.applicationSupportRoot()
            .appendingPathComponent("Models/\(plan.sourceSHA256)/Source")
        XCTAssertTrue(FileManager.default.fileExists(atPath: importedRoot.appendingPathComponent("main.ldr").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: importedRoot.appendingPathComponent("child.ldr").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: importedRoot.appendingPathComponent("custom.dat").path))
    }

    func testFolderWithMultipleRootsRequiresSelection() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let stepped = Data("1 4 0 0 0 1 0 0 0 1 0 0 0 1 3005.dat\n0 STEP\n".utf8)
        try stepped.write(to: folder.appendingPathComponent("first.ldr"))
        try stepped.write(to: folder.appendingPathComponent("second.ldr"))

        do {
            _ = try await InstructionModelImporter().import(source: .folder(folder))
            XCTFail("Expected root selection")
        } catch let InstructionImportError.rootSelectionRequired(candidates) {
            XCTAssertEqual(candidates, ["first.ldr", "second.ldr"])
        }
    }

    func testInvalidImportDoesNotPublishAVisibleModel() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("1 4 0 0 0 1 0 0 0 1 0 0 0 1 3005.dat\n".utf8)
            .write(to: folder.appendingPathComponent("unstepped.ldr"))
        let models = try InstructionModelImporter.applicationSupportRoot().appendingPathComponent("Models")
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: models.path)) ?? [])

        await XCTAssertThrowsErrorAsync {
            _ = try await InstructionModelImporter().import(source: .folder(folder))
        }

        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: models.path)) ?? [])
        XCTAssertEqual(after, before)
    }

    func testVerifyWritesSidecarMarkerAndSkipsRehashUntilForced() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let asset = folder.appendingPathComponent("asset.bin")
        let original = Data("bricky-asset-payload".utf8)
        try original.write(to: asset)
        let digest = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
        let downloader = VerifiedAssetDownloader()
        let expectedBytes = Int64(original.count)

        let initialResult = try await downloader.verify(asset, expectedBytes: expectedBytes, expectedSHA256: digest)
        XCTAssertTrue(initialResult)
        let marker = folder.appendingPathComponent("asset.bin.verified")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))

        // Same size and restored modification time, different bytes: the quick
        // path trusts the marker by design, and `force` re-hashes.
        let attributes = try FileManager.default.attributesOfItem(atPath: asset.path)
        let modified = try XCTUnwrap(attributes[.modificationDate] as? Date)
        var tampered = original
        tampered[0] = tampered[0] &+ 1
        try tampered.write(to: asset)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: asset.path)
        let restoredAttributes = try FileManager.default.attributesOfItem(atPath: asset.path)
        let restoredModified = try XCTUnwrap(restoredAttributes[.modificationDate] as? Date)
        XCTAssertEqual(
            restoredModified.timeIntervalSince1970,
            modified.timeIntervalSince1970,
            accuracy: 0.000_5,
            "The filesystem did not preserve the timestamp precision required by the marker fast path"
        )

        let quickResult = try await downloader.verify(asset, expectedBytes: expectedBytes, expectedSHA256: digest)
        XCTAssertTrue(quickResult)
        let forcedResult = try await downloader.verify(asset, expectedBytes: expectedBytes, expectedSHA256: digest, force: true)
        XCTAssertFalse(forcedResult)
        // The failed forced hash removed the marker, so the quick path is gone.
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let recheckedResult = try await downloader.verify(asset, expectedBytes: expectedBytes, expectedSHA256: digest)
        XCTAssertFalse(recheckedResult)
    }

    private func makeTemporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
