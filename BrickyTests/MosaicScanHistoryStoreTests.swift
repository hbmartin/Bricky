import XCTest
import UIKit
@testable import Bricky

@MainActor
final class MosaicScanHistoryStoreTests: XCTestCase {

    private var store: MosaicScanHistoryStore { .shared }

    override func setUp() {
        super.setUp()
        store.deleteAll()
    }

    override func tearDown() {
        store.deleteAll()
        super.tearDown()
    }

    private func solidImage(_ color: UIColor = .systemBlue) -> UIImage {
        let size = CGSize(width: 32, height: 32)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func line(_ color: String, qty: Int) -> MosaicPartLine {
        MosaicPartLine(
            part: "3024", color: color, qty: qty,
            ldrawColor: 0, bricklinkColor: 0, rebrickableColor: 0
        )
    }

    @discardableResult
    private func record(caption: String = "") -> UUID {
        store.record(
            gridWidth: 48,
            gridHeight: 48,
            brickCount: 120,
            studCount: 2304,
            totalParts: 2,
            parts: [line("Bright Blue", qty: 100), line("Black", qty: 20)],
            presetLabel: "48 × 48",
            sourceImage: solidImage(.systemBlue),
            thumbnail: solidImage(.systemGreen),
            ldrText: "0 Bricky Mosaic\n",
            pdfData: Data("%PDF-1.4 test".utf8),
            caption: caption
        )
    }

    func testRecordReturnsIdAndInsertsAtFront() {
        let first = record(caption: "First")
        let second = record(caption: "Second")

        XCTAssertEqual(store.entries.count, 2)
        XCTAssertEqual(store.entries.first?.id, second)
        XCTAssertEqual(store.entries.last?.id, first)
    }

    func testRecordWritesArtifactsToDisk() {
        let id = record()
        guard let entry = store.entries.first(where: { $0.id == id }) else {
            return XCTFail("Entry not found")
        }

        XCTAssertNotNil(store.sourceImage(for: entry))
        XCTAssertNotNil(store.thumbnail(for: entry))
        XCTAssertNotNil(store.ldrURL(for: entry))
        XCTAssertNotNil(store.pdfURL(for: entry))
    }

    func testUpdateCaptionMutatesAndPersists() {
        let id = record(caption: "Original")
        store.updateCaption(id: id, caption: "Edited", detail: "A nice mosaic.")

        let entry = store.entries.first { $0.id == id }
        XCTAssertEqual(entry?.caption, "Edited")
        XCTAssertEqual(entry?.detail, "A nice mosaic.")

        // Reload from disk to confirm persistence.
        store.reload()
        let reloaded = store.entries.first { $0.id == id }
        XCTAssertEqual(reloaded?.caption, "Edited")
        XCTAssertEqual(reloaded?.detail, "A nice mosaic.")
    }

    func testDeleteSingleEntryRemovesFiles() {
        let id = record()
        guard let entry = store.entries.first(where: { $0.id == id }) else {
            return XCTFail("Entry not found")
        }
        store.delete(entry)

        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertNil(store.ldrURL(for: entry))
        XCTAssertNil(store.pdfURL(for: entry))
        XCTAssertNil(store.sourceImage(for: entry))
    }

    func testDeleteByIdSet() {
        let a = record()
        let b = record()
        record()

        store.delete([a, b])

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertFalse(store.entries.contains { $0.id == a || $0.id == b })
    }

    func testDeleteAllClearsEverything() {
        record()
        record()
        store.deleteAll()
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testPersistenceSurvivesReload() {
        let id = record(caption: "Persisted")
        store.reload()
        XCTAssertTrue(store.entries.contains { $0.id == id && $0.caption == "Persisted" })
    }
}
