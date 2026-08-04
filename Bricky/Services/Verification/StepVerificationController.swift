import Foundation
import SwiftUI

/// Drives live geometric verification for the step being built. Frames and
/// registrations arrive through `RegistrationController.frameObserver`; the
/// verifier only ever judges under a locked registration, and its output is
/// advisory (ADR 0008) — the user confirms every step.
@MainActor
final class StepVerificationController: ObservableObject {
    @Published private(set) var verification: StepVerification?
    /// True once the verdict has been continuously complete for
    /// `stableCompleteInterval` — the gate for the one-tap Confirm & Next
    /// affordance. Never auto-advances (ADR 0008).
    @Published private(set) var isStablyComplete = false

    private var verifier: GeometricStepVerifier?
    private var completeSince: TimeInterval?
    private let stableCompleteInterval: TimeInterval = 2.0
    private var lastIngestTimestamp: TimeInterval = -.infinity
    /// The verifier renders several expected-depth maps per ingest; feeding
    /// it slower than the relay rate loses nothing at a 20–40 frame
    /// evidence budget.
    private let minimumInterval: TimeInterval = 0.2

    var statusLabel: String? {
        guard let verification else { return nil }
        switch verification.verdict {
        case .complete:
            return "Step looks complete"
        case .incomplete:
            return "Step not complete yet"
        case .misplaced(let offset):
            let direction = offset.x != 0
                ? (offset.x > 0 ? "one stud +x" : "one stud -x")
                : (offset.y > 0 ? "one stud +z" : "one stud -z")
            return "Brick looks misplaced (\(direction))"
        case .uncertain(let reason):
            switch reason {
            case .registrationNotLocked, .poseAmbiguous:
                return nil
            case .deltaUndetectable:
                return "Parts too small to verify by depth"
            case .occludedView:
                return "Move to see this step's parts"
            case .insufficientEvidence:
                return "Checking…"
            }
        }
    }

    var isComplete: Bool { verification?.verdict.isComplete == true }

    func begin(
        stepID: String,
        completedSnapshot: InstructionGeometrySnapshot,
        deltaSnapshot: InstructionGeometrySnapshot
    ) {
        verification = nil
        isStablyComplete = false
        completeSince = nil
        lastIngestTimestamp = -.infinity
        do {
            let verifier = try verifier ?? GeometricStepVerifier()
            self.verifier = verifier
            Task {
                await verifier.begin(
                    stepID: stepID,
                    completedSnapshot: completedSnapshot,
                    deltaSnapshot: deltaSnapshot
                )
            }
        } catch {
            verifier = nil
        }
    }

    /// Tap point for `RegistrationController.frameObserver`.
    func observe(frame: RegistrationFrameInput, registration: ModelRegistration) async {
        guard let verifier else { return }
        guard frame.timestamp - lastIngestTimestamp >= minimumInterval else { return }
        lastIngestTimestamp = frame.timestamp
        guard let result = try? await verifier.ingest(frame: frame, registration: registration) else { return }
        verification = result
        if result.verdict.isComplete {
            let since = completeSince ?? frame.timestamp
            completeSince = since
            isStablyComplete = frame.timestamp - since >= stableCompleteInterval
        } else {
            completeSince = nil
            isStablyComplete = false
        }
    }

    func stop() {
        verification = nil
        isStablyComplete = false
        completeSince = nil
        lastIngestTimestamp = -.infinity
        if let verifier {
            Task { await verifier.resetEvidence() }
        }
    }
}
