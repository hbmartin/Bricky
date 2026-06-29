import XCTest
@testable import Bricky

final class RebrickableSetServiceTests: XCTestCase {
    func testColorMappingNormalizesRebrickableNames() {
        XCTAssertEqual(RebrickableSetService.mappedColor("Light Bluish Gray"), "Gray")
        XCTAssertEqual(RebrickableSetService.mappedColor("Dark Bluish Gray"), "Dark Gray")
        XCTAssertEqual(RebrickableSetService.mappedColor("Reddish Brown"), "Brown")
        XCTAssertEqual(RebrickableSetService.mappedColor("Trans-Clear"), "Transparent")
        XCTAssertEqual(RebrickableSetService.mappedColor("Red"), "Red")
    }

    func testNotConfiguredThrows() async {
        let service = RebrickableSetService(apiKey: nil, proxyEndpoint: nil)
        XCTAssertFalse(service.isConfigured)
        do {
            _ = try await service.fetchParts(for: "60431")
            XCTFail("expected error")
        } catch let e as RebrickableSetError {
            XCTAssertEqual(e, .notConfigured)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testFullBOMReplacesSampleForCompletion() {
        let store = SetCollectionStore.shared
        let setNumber = "test-bom-set"
        let legoSet = LegoSet(id: setNumber, setNumber: setNumber, name: "T", theme: "City",
                              year: 2024, pieceCount: 100,
                              pieces: [.init(partNumber: "3001", color: "Red", quantity: 5)])
        // No BOM: uses sample (5 pieces).
        XCTAssertEqual(store.effectivePieces(for: legoSet).count, 1)
        XCTAssertFalse(store.hasFullBOM(for: setNumber))
    }
}
