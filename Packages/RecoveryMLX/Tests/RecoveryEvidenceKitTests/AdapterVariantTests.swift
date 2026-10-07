import XCTest
@testable import RecoveryEvidenceKit

/// The adapter axis (ADR 0019) is invisible until set: the baseline's bytes
/// and id are what they were before it existed.
final class AdapterVariantTests: XCTestCase {
    func testBaselineVariantEncodingIsByteIdentical() throws {
        // Captured from the kit before the adapter axis existed.
        let golden = #"{"board_layout":"v1","check_target":"guide_camera","decode":"legacy","image_side":1024,"labels":"slot_step","prompt_style":"baseline","scoring":"generate","slot_order":"sorted","unique_slots":false,"vote":"borda_dedup"}"#
        XCTAssertEqual(String(decoding: try EvidenceSchema.encoder().encode(RecoveryInferenceVariant.baseline), as: UTF8.self), golden)
        XCTAssertEqual(try JSONDecoder().decode(RecoveryInferenceVariant.self, from: Data(golden.utf8)), .baseline)
    }

    func testAdapterAbsentKeepsBaselineID() throws {
        XCTAssertNil(RecoveryInferenceVariant.baseline.adapter)
        XCTAssertEqual(RecoveryInferenceVariant.baseline.id, "baseline")
        XCTAssertNoThrow(try RecoveryInferenceVariant.baseline.validate())
    }

    func testAdapterRoundTripsAndNamesID() throws {
        let variant = RecoveryInferenceVariant(scoring: .probe, adapter: "first-slot.v1@0123456789ab")
        XCTAssertEqual(variant.id, "scoring=probe,adapter=first-slot.v1@0123456789ab")
        XCTAssertNoThrow(try variant.validate())
        let encoded = try EvidenceSchema.encoder().encode(variant)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains(#""adapter":"first-slot.v1@0123456789ab""#))
        XCTAssertEqual(try EvidenceSchema.decoder().decode(RecoveryInferenceVariant.self, from: encoded), variant)
        XCTAssertEqual(RecoveryInferenceVariant(adapter: "smoke-1@0123456789ab").id, "adapter=smoke-1@0123456789ab")
    }

    func testMalformedAdapterIdentityIsInvalid() {
        for identity in ["", "name", "name@0123456789a", "name@0123456789abc", "Name@0123456789ab",
                         "name@0123456789AB", "a,b@0123456789ab", "a=b@0123456789ab", "@0123456789ab", "a@b@0123456789ab"] {
            XCTAssertFalse(RecoveryInferenceVariant.isValidAdapterIdentity(identity), identity)
            XCTAssertThrowsError(try RecoveryInferenceVariant(adapter: identity).validate(), identity)
        }
        XCTAssertTrue(RecoveryInferenceVariant.isValidAdapterIdentity("smoke_2026.10@deadbeef0123"))
    }
}
