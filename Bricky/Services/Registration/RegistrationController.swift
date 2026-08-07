import Foundation
import simd
import SwiftUI

/// MainActor bridge between the manual alignment flow, the depth-ICP tracker,
/// and SwiftUI. Manual ghost placement provides the coarse pose; the tracker
/// refines and holds it; nudges re-seed it (ADR 0009). The controller owns
/// the consuming task so views just observe `registration`.
@MainActor
final class RegistrationController: ObservableObject {
    @Published private(set) var registration: ModelRegistration?

    /// Called with every processed frame and the registration it produced —
    /// the verification pipeline taps this so one relay consumer serves both
    /// tracking and verification.
    var frameObserver: (@MainActor (RegistrationFrameInput, ModelRegistration) async -> Void)?

    private let tracker = DepthICPTracker()
    private var consumeTask: Task<Void, Never>?
    private var sample: ModelSurfaceSample?
    private var activeAlignmentID: UUID?

    /// The pose the AR overlay should render at, when the tracker has a
    /// usable estimate; nil means fall back to the manual alignment.
    var trackedTransform: simd_float4x4? {
        guard let registration else { return nil }
        switch registration.state {
        case .refining, .locked, .ambiguous:
            return registration.worldFromModel
        case .unplaced, .coarse, .lost:
            return nil
        }
    }

    var statusLabel: String? {
        guard let registration else { return nil }
        switch registration.state {
        case .unplaced: return nil
        case .coarse: return "Aligning…"
        case .refining: return "Refining…"
        case .locked: return "Locked"
        case .ambiguous: return "Ambiguous — nudge or move around"
        case .lost: return "Tracking lost"
        }
    }

    /// Installs the fit target for the physical build (the cumulative
    /// geometry before the current step). Empty samples keep the tracker
    /// off — nothing physical exists yet to register against.
    func setFitSample(_ sample: ModelSurfaceSample?) {
        self.sample = sample
    }

    /// Reconciles tracking with the manual alignment: placement starts the
    /// tracker, a nudge re-seeds the coarse pose, removal stops tracking.
    func alignmentChanged(_ alignment: ARAlignment?, relay: RegistrationFrameRelay) {
        guard let alignment else {
            stop()
            return
        }
        guard let sample, !sample.points.isEmpty else { return }
        if alignment.id == activeAlignmentID {
            let tracker = tracker
            Task {
                await tracker.setTarget(
                    sample,
                    coarseWorldFromModel: alignment.transform,
                    alignmentID: alignment.id
                )
            }
            return
        }
        activeAlignmentID = alignment.id
        consumeTask?.cancel()
        let tracker = tracker
        consumeTask = Task { [weak self] in
            await tracker.setTarget(
                sample,
                coarseWorldFromModel: alignment.transform,
                alignmentID: alignment.id
            )
            for await frame in relay.frames() {
                if Task.isCancelled { break }
                guard let update = await tracker.process(frame) else { continue }
                guard let self, !Task.isCancelled else { break }
                self.registration = update
                await self.frameObserver?(frame, update)
            }
        }
    }

    /// Re-seeds after a step confirm: the physical build grew by the
    /// confirmed delta, so the fit target changes while the pose carries
    /// over from the current track (ADR 0009 — re-fit on confirm). When no
    /// track is running because the previous step had no physical geometry,
    /// starts one from the manual alignment instead.
    func refit(alignment: ARAlignment?, relay: RegistrationFrameRelay) {
        guard let sample, !sample.points.isEmpty else { return }
        if consumeTask != nil, let alignmentID = activeAlignmentID {
            guard let seed = registration?.worldFromModel ?? alignment?.transform else { return }
            let tracker = tracker
            Task {
                await tracker.setTarget(sample, coarseWorldFromModel: seed, alignmentID: alignmentID)
            }
        } else if let alignment {
            alignmentChanged(alignment, relay: relay)
        }
    }

    func stop() {
        consumeTask?.cancel()
        consumeTask = nil
        activeAlignmentID = nil
        registration = nil
        let tracker = tracker
        Task { await tracker.stop() }
    }
}
