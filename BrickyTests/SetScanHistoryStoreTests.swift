import XCTest
@testable import Bricky

@MainActor
final class SetScanHistoryStoreTests: XCTestCase {
    private func sample(_ name: String, conf: Double) -> IdentifiedSet {
        IdentifiedSet(setNumber: "75192", name: name, confidence: conf, summary: "")
    }

    override func setUp() {
        super.setUp()
        SetScanHistoryStore.shared.deleteAll()
    }

    func testRecordInsertsNewestFirst() {
        SetScanHistoryStore.shared.record(candidates: [sample("A", conf: 0.9)], sourceImage: nil)
        SetScanHistoryStore.shared.record(candidates: [sample("B", conf: 0.8)], sourceImage: nil)
        XCTAssertEqual(SetScanHistoryStore.shared.entries.count, 2)
        XCTAssertEqual(SetScanHistoryStore.shared.entries.first?.topName, "B")
    }

    func testDeleteRemovesEntry() {
        let id = SetScanHistoryStore.shared.record(candidates: [sample("A", conf: 0.9)], sourceImage: nil)
        guard let e = SetScanHistoryStore.shared.entries.first(where: { $0.id == id }) else {
            return XCTFail("missing")
        }
        SetScanHistoryStore.shared.delete(e)
        XCTAssertTrue(SetScanHistoryStore.shared.entries.isEmpty)
    }

    func testTopConfidenceReflectsFirstCandidate() {
        SetScanHistoryStore.shared.record(
            candidates: [sample("A", conf: 0.42), sample("B", conf: 0.1)], sourceImage: nil)
        XCTAssertEqual(SetScanHistoryStore.shared.entries.first?.topConfidence ?? 0, 0.42, accuracy: 0.001)
    }
}
