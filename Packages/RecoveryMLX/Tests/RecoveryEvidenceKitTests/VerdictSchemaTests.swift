import XCTest
@testable import RecoveryEvidenceKit

/// The check grammar's bytes are evidence: they key the grammar cache and
/// are recorded as every check trace's `schema_json`. Any change must be a
/// deliberate, versioned one, never a side effect of re-serializing.
final class VerdictSchemaTests: XCTestCase {
    func testCheckGrammarBytesArePinned() {
        XCTAssertEqual(
            VerdictSchemasV1.checkGrammarJSON,
            #"{"type":"object","properties":{"result":{"type":"string","enum":["complete","incomplete","uncertain"]}},"required":["result"],"additionalProperties":false}"#
        )
    }

    func testCheckGrammarEnumIsTheVerdictEnum() throws {
        let schema = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(VerdictSchemasV1.checkGrammarJSON.utf8)) as? [String: Any]
        )
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let result = try XCTUnwrap(properties["result"] as? [String: Any])
        XCTAssertEqual(result["enum"] as? [String], CheckVerdictV1.allCases.map(\.rawValue))
        XCTAssertEqual(schema["required"] as? [String], ["result"])
        XCTAssertEqual(VerdictSchemasV1.checkVerdictValues, ["complete", "incomplete", "uncertain"])
    }
}
