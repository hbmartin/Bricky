import XCTest
@testable import Bricky

final class DocumentOpenRouterTests: XCTestCase {
    func testLDrawFilesImportInAnyCase() {
        for name in ["castle.mpd", "Tower.LDR", "set.Mpd"] {
            let url = URL(fileURLWithPath: "/tmp/\(name)")
            XCTAssertEqual(DocumentOpenRouter.route(url), .importFile(url), name)
        }
    }

    func testEverythingElseIsRejectedWithAReason() {
        for url in [
            URL(string: "https://example.com/castle.mpd")!,
            URL(fileURLWithPath: "/tmp/3001.dat"),
            URL(fileURLWithPath: "/tmp/instructions.pdf"),
            URL(fileURLWithPath: "/tmp/bundle.zip")
        ] {
            guard case .rejected(let reason) = DocumentOpenRouter.route(url) else {
                return XCTFail("\(url) must be rejected")
            }
            XCTAssertFalse(reason.isEmpty)
        }
    }

    func testFoldersAreSentToTheLibraryImporter() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("model-\(UUID().uuidString).ldr", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        guard case .rejected(let reason) = DocumentOpenRouter.route(folder) else {
            return XCTFail("a folder, even one named .ldr, needs the root picker")
        }
        XCTAssertTrue(reason.contains("Import Folder"))
    }

    func testInboxCopiesAreRecognised() {
        XCTAssertTrue(DocumentOpenRouter.isInboxCopy(URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/X/Documents/Inbox/castle.mpd")))
        XCTAssertFalse(DocumentOpenRouter.isInboxCopy(URL(fileURLWithPath: "/private/var/mobile/Library/Mobile Documents/castle.mpd")))
        XCTAssertFalse(DocumentOpenRouter.isInboxCopy(URL(fileURLWithPath: "/Inbox/castle.mpd")))
    }
}
