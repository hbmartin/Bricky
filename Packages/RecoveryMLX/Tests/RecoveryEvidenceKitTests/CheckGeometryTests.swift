import XCTest
@testable import RecoveryEvidenceKit

/// The check pose and delta box are optional trailing fields: rows and
/// captures written before them still decode, and they survive retargeting.
final class CheckGeometryTests: XCTestCase {
    private let geometry = CheckGeometryRecord(
        deltaBox: .init(x: 0.25, y: 0.5, width: 0.125, height: 0.25), deltaPixels: 42, gridWidth: 256, gridHeight: 192
    )

    private func checkRow(geometry: CheckGeometryRecord?) -> EvidenceTraceRow {
        EvidenceTraceRow(
            traceVersion: 1, traceID: UUID(), sessionID: UUID(), pass: .check, passIndex: 0, captureID: UUID(),
            captureAngle: "center", boardRelativePath: "b.jpg", tileRelativePaths: ["A": "tiles/t/A.jpg"],
            candidateStepIndices: ["A": 4], candidateStepIDs: ["A": "m#5"], prompt: "p", schemaJSON: "{}",
            maxTokens: 48, rawOutput: #"{"result":"complete"}"#, decodeError: nil, termination: "accepted",
            generatedTokens: 1, latencyMilliseconds: 1, memoryFootprintBytes: nil, modelRevision: "r",
            createdAt: Date(timeIntervalSince1970: 0),
            variant: .baseline, alternateTileRelativePaths: ["registered": "tiles/t/A.registered.jpg"],
            checkGeometry: geometry
        )
    }

    func testCheckGeometryIsSnakeCaseAndOmittedWhenAbsent() throws {
        let encoded = try XCTUnwrap(String(data: EvidenceSchema.encoder().encode(checkRow(geometry: geometry)), encoding: .utf8))
        XCTAssertTrue(encoded.contains(#""check_geometry""#))
        XCTAssertTrue(encoded.contains(#""delta_box""#))
        XCTAssertTrue(encoded.contains(#""delta_pixels":42"#))
        XCTAssertTrue(encoded.contains(#""coordinate_space":"upright_capture_normalized""#))
        let without = try XCTUnwrap(String(data: EvidenceSchema.encoder().encode(checkRow(geometry: nil)), encoding: .utf8))
        XCTAssertFalse(without.contains("check_geometry"))
    }

    func testRowsAndCapturesFromBeforeTheFieldsStillDecode() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: EvidenceSchema.encoder().encode(checkRow(geometry: geometry))) as? [String: Any]
        )
        object.removeValue(forKey: "check_geometry")
        let old = try EvidenceSchema.decoder().decode(EvidenceTraceRow.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.checkGeometry)

        let capture = #"""
        {"capture_id":"7C3B1C2E-1A61-4D7B-9B3F-0E0B6B9C9D11","image_relative_path":"captures/a.jpg",
         "camera_transform":[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1],"camera_intrinsics":[1,0,0,0,1,0,0,0,1],
         "camera_image_resolution":[1920,1440],"alignment_id":"7C3B1C2E-1A61-4D7B-9B3F-0E0B6B9C9D12",
         "angle":"center","captured_at":"2026-10-06T00:00:00Z"}
        """#
        let record = try EvidenceSchema.decoder().decode(EvidenceCaptureRecord.self, from: Data(capture.utf8))
        XCTAssertNil(record.worldFromModel)
    }

    func testRetargetedRowKeepsCheckGeometry() throws {
        let retargeted = try XCTUnwrap(checkRow(geometry: geometry).retargeted(to: .registered))
        XCTAssertEqual(retargeted.checkTarget, .registered)
        XCTAssertEqual(retargeted.checkGeometry, geometry)
    }
}
