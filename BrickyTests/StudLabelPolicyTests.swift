import RecoveryEvidenceKit
import XCTest
@testable import Bricky

/// A capture is labelled only when the staged truth says what was built and
/// the pose it was taken under was locked well clear of a lattice alias.
final class StudLabelPolicyTests: XCTestCase {
    private func capture(
        pose: Bool = true, state: String? = "locked", margin: Float? = 2.0
    ) -> EvidenceCaptureRecord {
        EvidenceCaptureRecord(
            captureID: UUID(), imageRelativePath: "captures/a.jpg", cameraTransform: Array(repeating: 0, count: 16),
            cameraIntrinsics: Array(repeating: 0, count: 9), cameraImageResolution: [1920, 1440], alignmentID: UUID(),
            angle: "center", capturedAt: Date(timeIntervalSince1970: 0),
            worldFromModel: pose ? Array(repeating: 0, count: 16) : nil,
            registrationState: state, latticeMargin: margin, latticeRunnerUp: "shift_x_pos"
        )
    }

    private let staged = EvidenceGroundTruth(kind: .staged, expectedCompletedCount: 3)
    private let confirmed = EvidenceGroundTruth(kind: .confirmed, expectedCompletedCount: 3)

    private func refusal(_ capture: EvidenceCaptureRecord, _ truth: EvidenceGroundTruth, confirmed: Bool = false) -> StudLabelPolicy.Refusal? {
        StudLabelPolicy.refusal(capture: capture, truth: truth, includeConfirmed: confirmed)
    }

    func testALockedStagedCaptureIsLabelled() {
        XCTAssertNil(refusal(capture(), staged))
        XCTAssertNil(refusal(capture(margin: 1.5), staged), "the boundary is inclusive")
    }

    func testNoStagedTruth() {
        XCTAssertEqual(refusal(capture(), .unlabeled), .noStagedTruth)
        XCTAssertEqual(refusal(capture(), confirmed), .noStagedTruth, "confirmed sessions only on request")
        XCTAssertNil(refusal(capture(), confirmed, confirmed: true))
    }

    func testUnregistered() {
        XCTAssertEqual(refusal(capture(pose: false), staged), .unregistered)
    }

    func testNoRegistrationSnapshot() {
        XCTAssertEqual(refusal(capture(state: nil, margin: nil), staged), .noRegistrationSnapshot)
    }

    func testNotLocked() {
        XCTAssertEqual(refusal(capture(state: "ambiguous", margin: 1.1), staged), .notLocked)
    }

    func testAliasingRisk() {
        // Locked (the lock rule is 1.3) but within the label margin.
        XCTAssertEqual(refusal(capture(margin: 1.4), staged), .aliasingRisk)
    }
}
