import Foundation

/// Geometric-first recovery with the full VLM estimator as automatic
/// fallback (ADR 0010). The geometric path concludes or steps aside — any
/// error or inconclusive fit falls through to the hierarchical estimator
/// unchanged, so recovery is never worse than the VLM baseline.
///
/// The fallback is optional: geometric recovery is never gated on VLM
/// admission. Without a fallback, a pass that cannot conclude returns an
/// insufficient estimate and the user picks the step manually. The same
/// happens when the device is too hot to start VLM recovery
/// (`InferencePolicy`, ADR 0003 amendment): the geometric pass still runs.
actor CompositeRecoveryEstimator: RecoveryEstimating {
    private let geometric: GeometricRecoveryEstimator?
    private let fallback: (any RecoveryEstimating)?
    private let thermalState: @Sendable () -> ProcessInfo.ThermalState

    init(
        geometric: GeometricRecoveryEstimator?,
        fallback: (any RecoveryEstimating)?,
        thermalState: @escaping @Sendable () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState }
    ) {
        self.geometric = geometric
        self.fallback = fallback
        self.thermalState = thermalState
    }

    func estimate(
        captures: [RecoveryCapture],
        model: InstructionPlan,
        alignment: ARAlignment
    ) async throws -> RecoveryEstimate {
        // Only this estimator sees both legs, so only it can report what the
        // user actually waited for. Each underlying estimator times itself,
        // which under-reports a fallback by exactly the geometric attempt —
        // the cost the 20 s composite budget exists to cover.
        let started = ContinuousClock.now
        var geometricAttempted = false
        if let geometric {
            geometricAttempted = true
            do {
                if let estimate = try await geometric.estimate(
                    model: model,
                    alignment: alignment,
                    captureIDs: captures.map(\.id)
                ) {
                    return estimate
                }
            } catch is CancellationError {
                // Cancelled analysis must not fall through and start VLM
                // inference.
                throw CancellationError()
            } catch {
                // Any other geometric failure steps aside per ADR 0010.
            }
        }
        guard let fallback else {
            guard geometricAttempted else {
                throw RecoveryError.invalidCaptureSet(
                    reason: "No depth observation was captured and the on-device model is not available. Pick your step manually."
                )
            }
            return RecoveryEstimate(
                rankedStepIDs: [],
                certainty: .insufficient,
                modelRevision: "depth-icp-geometric-v1",
                latencyMilliseconds: Self.milliseconds(started.duration(to: .now)),
                captureIDs: captures.map(\.id),
                insufficiencyCause: .geometricInconclusiveWithoutFallback,
                method: .geometric
            )
        }
        // Read when the fallback would start, not when the estimate began:
        // the geometric pass may have run while the device heated.
        guard InferencePolicy.decide(.recovery, thermal: thermalState()) == .allowed else {
            return RecoveryEstimate(
                rankedStepIDs: [],
                certainty: .insufficient,
                modelRevision: RecoveryModelManager.revision,
                latencyMilliseconds: Self.milliseconds(started.duration(to: .now)),
                captureIDs: captures.map(\.id),
                insufficiencyCause: .thermalDeferred,
                // The VLM pipeline produced this outcome by declining, after
                // the geometric pass when there was one — the same
                // accounting as a fallback that ran.
                method: geometricAttempted ? .composite : .vlm
            )
        }
        let estimate = try await fallback.estimate(captures: captures, model: model, alignment: alignment)
        // `.composite` means "the geometric pass ran and did not conclude";
        // `.vlm` means it was never possible. They share a latency budget but
        // are different failures, and only the first is worth optimising.
        return estimate.restamped(
            method: geometricAttempted ? .composite : .vlm,
            latencyMilliseconds: Self.milliseconds(started.duration(to: .now))
        )
    }

    static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds) * 1_000
            + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    }
}
