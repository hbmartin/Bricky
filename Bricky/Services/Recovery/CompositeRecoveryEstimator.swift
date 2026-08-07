import Foundation

/// Geometric-first recovery with the full VLM estimator as automatic
/// fallback (ADR 0010). The geometric path concludes or steps aside — any
/// error or inconclusive fit falls through to the hierarchical estimator
/// unchanged, so recovery is never worse than the VLM baseline.
actor CompositeRecoveryEstimator: RecoveryEstimating {
    private let geometric: GeometricRecoveryEstimator?
    private let fallback: any RecoveryEstimating

    init(geometric: GeometricRecoveryEstimator?, fallback: any RecoveryEstimating) {
        self.geometric = geometric
        self.fallback = fallback
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
