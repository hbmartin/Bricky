import XCTest
@testable import RecoveryEvidenceKit

/// What a geometric recovery replay needs beyond the planes: the alignment
/// the device fit from, the part pack it rendered with, and a way to say two
/// fits are the same measurement.
final class RecoveryReplayInputTests: XCTestCase {
    private func depthRecord(coarse: [Float]?) -> EvidenceDepthFrameRecord {
        EvidenceDepthFrameRecord(
            depthVersion: EvidenceSchema.depthVersion, captureID: UUID(uuidString: "7C3B1C2E-1A61-4D7B-9B3F-0E0B6B9C9D13")!,
            width: 4, height: 3, depthIntrinsics: Array(repeating: 1, count: 9), worldFromCamera: Array(repeating: 0, count: 16),
            timestamp: 3, depthRelativePath: "depth/x.depth", confidenceRelativePath: "depth/x.confidence",
            rawDepthRelativePath: nil, rawConfidenceRelativePath: nil, coarseWorldFromModel: coarse
        )
    }

    private func session(partPack: String?) -> EvidenceSessionFile {
        EvidenceSessionFile(
            sessionVersion: EvidenceSchema.sessionVersion, sessionID: UUID(uuidString: "7C3B1C2E-1A61-4D7B-9B3F-0E0B6B9C9D11")!,
            createdAt: Date(timeIntervalSince1970: 1_790_000_000), instructionSHA256: "abc",
            authoredModelID: UUID(uuidString: "7C3B1C2E-1A61-4D7B-9B3F-0E0B6B9C9D12")!,
            modelTitle: "Tower", stepCount: 12, modelRevision: "r", deviceModel: "iPhone18,1", operatingSystem: "27.0",
            appVersion: "1.0", captures: [], staged: nil, groundTruth: .unlabeled, estimate: nil, analysisError: nil,
            partPackVersion: partPack
        )
    }

    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: EvidenceSchema.encoder().encode(value)) as? [String: Any])
    }

    func testCoarsePoseAndPartPackVersionRoundTripUnderSnakeCaseKeys() throws {
        let pose: [Float] = [1, 0, 0, 0.01, 0, 1, 0, 0.02, 0, 0, 1, 0.03, 0, 0, 0, 1]
        let frame = try object(depthRecord(coarse: pose))
        XCTAssertEqual((frame["coarse_world_from_model"] as? [Double])?.map(Float.init), pose)
        let decoded = try EvidenceSchema.decoder().decode(
            EvidenceDepthFrameRecord.self, from: EvidenceSchema.encoder().encode(depthRecord(coarse: pose))
        )
        XCTAssertEqual(decoded.coarseWorldFromModel, pose)

        let file = try object(session(partPack: "2026-07"))
        XCTAssertEqual(file["part_pack_version"] as? String, "2026-07")

        // Records written before the fields existed decode, with nothing set,
        // and records without them encode exactly as before.
        XCTAssertNil(try object(depthRecord(coarse: nil))["coarse_world_from_model"])
        XCTAssertNil(try object(session(partPack: nil))["part_pack_version"])
        var old = file
        old.removeValue(forKey: "part_pack_version")
        let oldSession = try EvidenceSchema.decoder().decode(
            EvidenceSessionFile.self, from: JSONSerialization.data(withJSONObject: old)
        )
        XCTAssertNil(oldSession.partPackVersion)
    }

    func testRelayMeasurementsRoundTripUnderSnakeCaseKeys() throws {
        let record = EvidenceDepthFrameRecord(
            depthVersion: EvidenceSchema.depthVersion, captureID: UUID(), width: 4, height: 3,
            depthIntrinsics: Array(repeating: 1, count: 9), worldFromCamera: Array(repeating: 0, count: 16),
            timestamp: 3, depthRelativePath: "w.depth", confidenceRelativePath: "w.confidence",
            rawDepthRelativePath: nil, rawConfidenceRelativePath: nil,
            auxiliaryExtractMilliseconds: 2.5, segmentationWidth: 256, segmentationHeight: 192, segmentationBytesPerRow: 320
        )
        let json = try object(record)
        XCTAssertEqual(json["auxiliary_extract_ms"] as? Double, 2.5)
        XCTAssertEqual(json["segmentation_bytes_per_row"] as? Int, 320)
        let decoded = try EvidenceSchema.decoder().decode(EvidenceDepthFrameRecord.self, from: EvidenceSchema.encoder().encode(record))
        XCTAssertEqual(decoded.auxiliaryExtractMilliseconds, 2.5)
        XCTAssertEqual(decoded.segmentationWidth, 256)
        XCTAssertEqual(decoded.segmentationHeight, 192)
        XCTAssertEqual(decoded.segmentationBytesPerRow, 320)
    }

    private func fit(score: Float = 0.6, pose: [Float] = Array(repeating: 0.5, count: 16), id: UUID = UUID(), at date: Date = .now) -> GeometricFitRecord {
        GeometricFitRecord(
            fitVersion: EvidenceSchema.fitVersion, fitID: id, sessionID: UUID(), passIndex: 0, candidateIndex: 2,
            stepID: "main.ldr#3", score: score, inlierFraction: 0.8, visibleFraction: 0.7, unexplainedFraction: 0.1,
            phantomFraction: 0.05, rmsResidual: 0.002, latticeMargin: 1.4, worldFromModel: pose,
            disqualification: .none, conclusive: true, createdAt: date, latticeRunnerUp: "shift_x_plus"
        )
    }

    func testFitsCompareOnTheMeasurementNotTheRecordIdentity() {
        let device = fit(at: Date(timeIntervalSince1970: 1))
        // A replay mints its own id, session and timestamp.
        XCTAssertTrue(device.isSameFit(as: fit(at: Date(timeIntervalSince1970: 99))))
        XCTAssertFalse(device.isSameFit(as: fit(score: Float(0.6).nextUp)), "one ulp is a different measurement")
        var moved = Array(repeating: Float(0.5), count: 16)
        moved[3] = Float(0.5).nextDown
        XCTAssertFalse(device.isSameFit(as: fit(pose: moved)))
    }
}
