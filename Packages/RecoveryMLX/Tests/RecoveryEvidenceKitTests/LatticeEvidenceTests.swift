import XCTest
@testable import RecoveryEvidenceKit

/// Lattice evidence is optional and trailing: records written before it
/// still decode, and nothing new is written when there is nothing to say.
final class LatticeEvidenceTests: XCTestCase {
    private func frame(runnerUp: String?) -> VerificationWindowFrame {
        VerificationWindowFrame(
            frameID: UUID(), registrationState: "locked", worldFromModel: Array(repeating: 0, count: 16),
            rmsResidual: 0.002, inlierFraction: 0.8, latticeMargin: 1.25, verdictAfter: "complete",
            ingestMilliseconds: 9, latticeRunnerUp: runnerUp
        )
    }

    private func fit(runnerUp: String?) -> GeometricFitRecord {
        GeometricFitRecord(
            fitVersion: EvidenceSchema.fitVersion, fitID: UUID(), sessionID: UUID(), passIndex: 0, candidateIndex: 2,
            stepID: "m#3", score: 0.6, inlierFraction: 0.5, visibleFraction: 0.4, unexplainedFraction: 0.1,
            phantomFraction: 0.05, rmsResidual: 0.004, latticeMargin: 1.4, worldFromModel: Array(repeating: 0, count: 16),
            disqualification: .none, conclusive: false, createdAt: Date(timeIntervalSince1970: 0),
            latticeRunnerUp: runnerUp
        )
    }

    private func capture(state: String?, margin: Float?, runnerUp: String?) -> EvidenceCaptureRecord {
        EvidenceCaptureRecord(
            captureID: UUID(), imageRelativePath: "captures/a.jpg", cameraTransform: Array(repeating: 0, count: 16),
            cameraIntrinsics: Array(repeating: 0, count: 9), cameraImageResolution: [1920, 1440], alignmentID: UUID(),
            angle: "center", capturedAt: Date(timeIntervalSince1970: 0), worldFromModel: nil,
            registrationState: state, latticeMargin: margin, latticeRunnerUp: runnerUp
        )
    }

    private func json<T: Encodable>(_ value: T) throws -> String {
        try XCTUnwrap(String(data: EvidenceSchema.encoder().encode(value), encoding: .utf8))
    }

    func testRunnerUpOptionalOmittedWhenNil() throws {
        XCTAssertTrue(try json(frame(runnerUp: "shift_x_neg")).contains(#""lattice_runner_up":"shift_x_neg""#))
        XCTAssertFalse(try json(frame(runnerUp: nil)).contains("lattice_runner_up"))
        XCTAssertTrue(try json(fit(runnerUp: "yaw_90")).contains(#""lattice_runner_up":"yaw_90""#))
        XCTAssertFalse(try json(fit(runnerUp: nil)).contains("lattice_runner_up"))

        let stamped = try json(capture(state: "locked", margin: 1.5, runnerUp: "yaw_180"))
        XCTAssertTrue(stamped.contains(#""registration_state":"locked""#))
        XCTAssertTrue(stamped.contains(#""lattice_margin":1.5"#))
        XCTAssertTrue(stamped.contains(#""lattice_runner_up":"yaw_180""#))
        let bare = try json(capture(state: nil, margin: nil, runnerUp: nil))
        for key in ["registration_state", "lattice_margin", "lattice_runner_up"] {
            XCTAssertFalse(bare.contains(key), key)
        }
    }

    func testRecordsFromBeforeTheRunnerUpStillDecode() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: EvidenceSchema.encoder().encode(frame(runnerUp: "shift_z_pos"))) as? [String: Any]
        )
        object.removeValue(forKey: "lattice_runner_up")
        let oldFrame = try EvidenceSchema.decoder().decode(
            VerificationWindowFrame.self, from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(oldFrame.latticeRunnerUp)
        XCTAssertEqual(oldFrame.latticeMargin, 1.25)

        var fitObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: EvidenceSchema.encoder().encode(fit(runnerUp: "yaw_90"))) as? [String: Any]
        )
        fitObject.removeValue(forKey: "lattice_runner_up")
        XCTAssertNil(try EvidenceSchema.decoder().decode(
            GeometricFitRecord.self, from: JSONSerialization.data(withJSONObject: fitObject)
        ).latticeRunnerUp)

        let roundTrip = try EvidenceSchema.decoder().decode(
            EvidenceCaptureRecord.self,
            from: EvidenceSchema.encoder().encode(capture(state: "ambiguous", margin: 1.125, runnerUp: "shift_x_pos"))
        )
        XCTAssertEqual(roundTrip.registrationState, "ambiguous")
        XCTAssertEqual(roundTrip.latticeMargin, 1.125)
        XCTAssertEqual(roundTrip.latticeRunnerUp, "shift_x_pos")
    }
}
