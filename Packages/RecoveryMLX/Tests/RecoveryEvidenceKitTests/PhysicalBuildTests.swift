import XCTest
@testable import RecoveryEvidenceKit

/// `physical_build_id` is optional and trailing: sessions written before it
/// decode, and a session without one encodes exactly as before.
final class PhysicalBuildTests: XCTestCase {
    private func session(build: String?) -> EvidenceSessionFile {
        EvidenceSessionFile(
            sessionVersion: EvidenceSchema.sessionVersion, sessionID: UUID(uuidString: "7C3B1C2E-1A61-4D7B-9B3F-0E0B6B9C9D11")!,
            createdAt: Date(timeIntervalSince1970: 1_790_000_000), instructionSHA256: "abc", authoredModelID: UUID(uuidString: "7C3B1C2E-1A61-4D7B-9B3F-0E0B6B9C9D12")!,
            modelTitle: "Tower", stepCount: 12, modelRevision: "r", deviceModel: "iPhone18,1", operatingSystem: "27.0",
            appVersion: "1.0", captures: [], staged: nil, groundTruth: .unlabeled, estimate: nil, analysisError: nil,
            physicalBuildID: build
        )
    }

    func testSessionWithoutPhysicalBuildIDDecodes() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: EvidenceSchema.encoder().encode(session(build: "b-1a2b"))) as? [String: Any]
        )
        XCTAssertEqual(object["physical_build_id"] as? String, "b-1a2b")
        object.removeValue(forKey: "physical_build_id")
        let old = try EvidenceSchema.decoder().decode(EvidenceSessionFile.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.physicalBuildID)
    }

    func testPhysicalBuildIDOmittedWhenNilIsByteIdentical() throws {
        let encoded = try EvidenceSchema.encoder().encode(session(build: nil))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("physical_build_id"))
        // Decoding and re-encoding a session without the field changes no byte.
        let reencoded = try EvidenceSchema.encoder().encode(
            EvidenceSchema.decoder().decode(EvidenceSessionFile.self, from: encoded)
        )
        XCTAssertEqual(reencoded, encoded)
    }

    func testPhysicalBuildSlugRules() {
        for valid in ["b-1a2b", "kitchen-table-2", "a", String(repeating: "x", count: 32)] {
            XCTAssertTrue(EvidenceSessionFile.isValidPhysicalBuildID(valid), valid)
        }
        for invalid in ["", "B-1A2B", "two words", "b_1", "é", String(repeating: "x", count: 33)] {
            XCTAssertFalse(EvidenceSessionFile.isValidPhysicalBuildID(invalid), invalid)
        }
    }
}
