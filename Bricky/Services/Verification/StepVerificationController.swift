import Foundation
import SwiftUI

/// What the controller needs from a step verifier; `GeometricStepVerifier`
/// in the app, a fake in tests.
protocol StepVerifying: Actor {
    func begin(stepID: String, completedSnapshot: InstructionGeometrySnapshot, deltaSnapshot: InstructionGeometrySnapshot)
    func ingest(frame: RegistrationFrameInput, registration: ModelRegistration) async throws -> StepVerification
    func resetEvidence()
}

extension GeometricStepVerifier: StepVerifying {}

/// Drives live geometric verification for the step being built. Frames and
/// registrations arrive through `RegistrationController.frameObserver`; the
/// verifier only ever judges under a locked registration, and its output is
/// advisory (ADR 0008) — the user confirms every step.
///
/// Verification runs beside tracking, never inside it: `submit` keeps only
/// the newest frame and returns at once, and a single worker drains it. A
/// frame that arrives while the verifier is busy replaces the waiting one
/// instead of queueing, so a slow render costs verification frames, not
/// tracking frames.
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

    private let makeVerifier: () throws -> any StepVerifying
    private var verifier: (any StepVerifying)?
    /// Bumped on every `begin` and `stop`: a frame in flight across the step
    /// boundary must not publish into the new step's verification.
    private var generation = 0
    /// False while `begin` installs a step: a frame judged before the
    /// verifier holds the new geometry would be judged against the old.
    private var acceptingFrames = false
    private var pending: (frame: RegistrationFrameInput, registration: ModelRegistration)?
    private var worker: Task<Void, Never>?
    private var completeSince: TimeInterval?
    private let stableCompleteInterval: TimeInterval = 2.0
    private var lastIngestTimestamp: TimeInterval = -.infinity
    /// The verifier renders several expected-depth maps per ingest; feeding
    /// it slower than the relay rate loses nothing at a 20–40 frame
    /// evidence budget.
    private let minimumInterval: TimeInterval = 0.2

    init(makeVerifier: @escaping () throws -> any StepVerifying = { try GeometricStepVerifier() }) {
        self.makeVerifier = makeVerifier
    }

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
        let beginGeneration = generation
        acceptingFrames = false
        pending = nil
        verification = nil
        isStablyComplete = false
        completeSince = nil
        lastIngestTimestamp = -.infinity
        do {
            let verifier = try verifier ?? makeVerifier()
            self.verifier = verifier
            unavailableReason = nil
            // Awaited, with frames refused until it returns, so no frame can
            // reach the verifier before it holds this step's snapshots.
            await verifier.begin(
                stepID: stepID,
                completedSnapshot: completedSnapshot,
                deltaSnapshot: deltaSnapshot
            )
            // A later begin() or stop() owns the state now.
            if beginGeneration == generation {
                acceptingFrames = true
            }
        } catch {
            verifier = nil
            unavailableReason = "Depth verification is unavailable: \(error.localizedDescription)"
        }
    }

    /// Tap point for `RegistrationController.frameObserver`. Returns
    /// immediately: the frame replaces any frame still waiting, and the
    /// worker judges it when the verifier is free.
    func submit(frame: RegistrationFrameInput, registration: ModelRegistration) {
        guard verifier != nil, acceptingFrames else { return }
        guard frame.timestamp - lastIngestTimestamp >= minimumInterval else { return }
        lastIngestTimestamp = frame.timestamp
        pending = (frame, registration)
        if worker == nil {
            worker = Task { [weak self] in await self?.drain() }
        }
    }

    private func drain() async {
        while let next = pending, let verifier, acceptingFrames {
            pending = nil
            let ingestGeneration = generation
            let result = try? await verifier.ingest(frame: next.frame, registration: next.registration)
            // A begin() or stop() while this ingest was in flight makes the
            // result stale.
            guard let result, ingestGeneration == generation else { continue }
            publish(result, at: next.frame.timestamp)
        }
        worker = nil
    }

    private func publish(_ result: StepVerification, at timestamp: TimeInterval) {
        verification = result
        if result.verdict.isComplete {
            let since = completeSince ?? timestamp
            completeSince = since
            isStablyComplete = timestamp - since >= stableCompleteInterval
        } else {
            completeSince = nil
            isStablyComplete = false
        }
    }

    func stop() {
        // Invalidates any in-flight ingest first, so a result landing after
        // this stop cannot repopulate the cleared verification.
        generation += 1
        acceptingFrames = false
        pending = nil
        verification = nil
        isStablyComplete = false
        completeSince = nil
        lastIngestTimestamp = -.infinity
        if let verifier {
            Task { await verifier.resetEvidence() }
        }
    }
}
