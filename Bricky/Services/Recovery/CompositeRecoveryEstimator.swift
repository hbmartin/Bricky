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
        if let geometric,
           let estimate = try? await geometric.estimate(
               model: model,
               alignment: alignment,
               captureIDs: captures.map(\.id)
           ) {
            return estimate
        }
        return try await fallback.estimate(captures: captures, model: model, alignment: alignment)
    }
}
