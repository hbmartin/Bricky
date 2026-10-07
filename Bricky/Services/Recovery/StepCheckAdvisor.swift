import Foundation

/// What answers a photo step check (M3.4, ADR 0018). The on-device VLM is
/// the only advisor whose verdict is shown. A Foundation Models advisor runs
/// beside it in shadow (`ShadowCheckRunner`); ADR 0018 decides from device
/// rows whether it may ever replace the VLM here. "None" is the existing
/// admission gate: without an admitted VLM there is no photo check.
@MainActor
protocol StepCheckAdvisor {
    func check(
        capture: RecoveryCapture,
        plan: InstructionPlan,
        step: AuthoredStep,
        registered: ARAlignment?
    ) async throws -> VLMStepCheckService.Outcome
}

extension VLMStepCheckService: StepCheckAdvisor {}
