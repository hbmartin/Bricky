import Foundation
import RecoveryEvidenceKit

/// Which photo captures may be given stud labels (iOS 27 Phase 4,
/// ADR 0020). A label is the authored studs projected through the pose the
/// registration had when the photo was taken, so it is only as good as
/// that pose. A pose near a lattice alias would label every stud one pitch
/// off, consistently and silently: exactly the cases the labels exist to
/// fix. So the policy refuses rather than guesses, and the staged
/// declaration — never the registration — says what was built.
enum StudLabelPolicy {
    enum Refusal: String, Sendable, CaseIterable {
        /// No staged declaration says what was built (or a confirmed
        /// session, unless asked for).
        case noStagedTruth = "no_staged_truth"
        /// No locked model pose was recorded with the photo.
        case unregistered
        /// The capture predates the registration snapshot (C1).
        case noRegistrationSnapshot = "no_registration_snapshot"
        case notLocked = "not_locked"
        /// Locked, but a lattice alternative came within the margin.
        case aliasingRisk = "aliasing_risk"
    }

    /// Above the lock rule's 1.3: a lock that only just cleared it is
    /// exactly where a one-pitch alias hides.
    static let minimumLatticeMargin: Float = 1.5

    /// Why `capture` cannot be labelled, or nil when it can.
    static func refusal(
        capture: EvidenceCaptureRecord, truth: EvidenceGroundTruth, includeConfirmed: Bool
    ) -> Refusal? {
        switch truth.kind {
        case .staged:
            break
        case .confirmed where includeConfirmed:
            break
        default:
            return .noStagedTruth
        }
        guard capture.worldFromModel?.count == 16 else { return .unregistered }
        guard let state = capture.registrationState, let margin = capture.latticeMargin else {
            return .noRegistrationSnapshot
        }
        guard state == "locked" else { return .notLocked }
        guard margin >= minimumLatticeMargin else { return .aliasingRisk }
        return nil
    }
}
