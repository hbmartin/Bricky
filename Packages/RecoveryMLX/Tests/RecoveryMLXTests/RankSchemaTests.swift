import XCTest
@testable import RecoveryMLX

final class RankSchemaTests: XCTestCase {
    private struct DecodedSchema {
        let enumLetters: [String]
        let minItems: Int
        let maxItems: Int
    }

    private func decode(_ schema: String) throws -> DecodedSchema {
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any]
        )
        let properties = try XCTUnwrap(object["properties"] as? [String: Any])
        let ranking = try XCTUnwrap(properties["ranking"] as? [String: Any])
        let items = try XCTUnwrap(ranking["items"] as? [String: Any])
        return DecodedSchema(
            enumLetters: try XCTUnwrap(items["enum"] as? [String]),
            minItems: try XCTUnwrap(ranking["minItems"] as? Int),
            maxItems: try XCTUnwrap(ranking["maxItems"] as? Int)
        )
    }

    func testSchemaMatchesSlotCount() throws {
        let decoded = try decode(MLXRecoveryRuntime.rankSchema(slotCount: 3))
        XCTAssertEqual(decoded.enumLetters, ["A", "B", "C"])
        XCTAssertEqual(decoded.minItems, 1)
        XCTAssertEqual(decoded.maxItems, 3)
    }

    func testFullBoardPermitsAllEightSlots() throws {
        let decoded = try decode(MLXRecoveryRuntime.rankSchema(slotCount: 8))
        XCTAssertEqual(decoded.enumLetters, ["A", "B", "C", "D", "E", "F", "G", "H"])
        XCTAssertEqual(decoded.maxItems, 8)
    }

    func testSlotCountIsClampedToValidRange() throws {
        XCTAssertEqual(
            MLXRecoveryRuntime.rankSchema(slotCount: 0),
            MLXRecoveryRuntime.rankSchema(slotCount: 1)
        )
        XCTAssertEqual(
            MLXRecoveryRuntime.rankSchema(slotCount: 99),
            MLXRecoveryRuntime.rankSchema(slotCount: 8)
        )
        let single = try decode(MLXRecoveryRuntime.rankSchema(slotCount: 1))
        XCTAssertEqual(single.enumLetters, ["A"])
        XCTAssertEqual(single.maxItems, 1)
    }

    func testSchemaStillRequiresStatusAndRanking() throws {
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(MLXRecoveryRuntime.rankSchema(slotCount: 4).utf8)
            ) as? [String: Any]
        )
        XCTAssertEqual(try XCTUnwrap(object["required"] as? [String]).sorted(), ["ranking", "status"])
        let properties = try XCTUnwrap(object["properties"] as? [String: Any])
        let status = try XCTUnwrap(properties["status"] as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(status["enum"] as? [String]), ["matched", "insufficient"])
    }
}
