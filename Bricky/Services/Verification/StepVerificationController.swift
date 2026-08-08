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
    /// Set when the geometric verifier cannot be constructed (no Metal);
    /// surfaced so the guide can explain the missing check.
    @Published private(set) var unavailableReason: String?

    private var verifier: GeometricStepVerifier?
    /// Bumped on every `begin`: a frame in flight across the step boundary
    /// must not publish into the new step's verification.
    private var generation = 0
    private var completeSince: TimeInterval?
    private let stableCompleteInterval: TimeInterval = 2.0
    private var lastIngestTimestamp: TimeInterval = -.infinity
    /// The verifier renders several expected-depth maps per ingest; feeding
    /// it slower than the relay rate loses nothing at a 20–40 frame
    /// evidence budget.
    private let minimumInterval: TimeInterval = 0.2

    var statusLabel: String? {
        guard let verification else { return unavailableReason }
        switch verification.verdict {
        case .complete:
            return "Step looks complete"
        case .incomplete:
            return "Step not complete yet"
        case .misplaced:
            // Model-space axes mean nothing to the user; the offset stays in
            // the verdict for diagnostics only.
            return "Brick looks misplaced by about one stud"
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
    ) async {
        generation += 1
        verification = nil
        isStablyComplete = false
        completeSince = nil
        lastIngestTimestamp = -.infinity
        do {
            let verifier = try verifier ?? GeometricStepVerifier()
            self.verifier = verifier
            unavailableReason = nil
            // Awaited so no observe() can reach the verifier before it holds
            // this step's snapshots — an unstructured Task here let a frame
            // race the setup and judge the new step against the old geometry.
            await verifier.begin(
                stepID: stepID,
                completedSnapshot: completedSnapshot,
                deltaSnapshot: deltaSnapshot
            )
        } catch {
            verifier = nil
            unavailableReason = "Depth verification is unavailable: \(error.localizedDescription)"
        }
    }

    /// Tap point for `RegistrationController.frameObserver`.
    func observe(frame: RegistrationFrameInput, registration: ModelRegistration) async {
        guard let verifier else { return }
        guard frame.timestamp - lastIngestTimestamp >= minimumInterval else { return }
        lastIngestTimestamp = frame.timestamp
        let ingestGeneration = generation
        guard let result = try? await verifier.ingest(frame: frame, registration: registration) else { return }
        // A begin() while this ingest was in flight makes the result stale.
        guard ingestGeneration == generation else { return }
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
        // Invalidates any in-flight observe() first, so a result landing
        // after this stop cannot repopulate the cleared verification.
        generation += 1
        verification = nil
        isStablyComplete = false
        completeSince = nil
        lastIngestTimestamp = -.infinity
        if let verifier {
            Task { await verifier.resetEvidence() }
        }
    }
}
