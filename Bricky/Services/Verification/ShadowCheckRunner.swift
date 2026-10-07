import BrickyLanguage
import Foundation

/// Runs the Foundation Models step-check advisor beside an AR photo check,
/// in shadow (M3.4, ADR 0018). It starts only after the VLM has returned,
/// so it never shares a moment of the primary check, and the primary
/// verdict is published without waiting for it. Its answer is recorded,
/// never shown. A new check or leaving the foreground cancels it; ending
/// the check drains it, within a deadline, before the session is finalized.
@MainActor
final class ShadowCheckRunner {
    private let makeAdvisor: () -> (any StepCheckModelAdvisor)?
    private var task: Task<Void, Never>?

    init(makeAdvisor: @escaping () -> (any StepCheckModelAdvisor)? = { ShadowCheckRunner.systemAdvisor() }) {
        self.makeAdvisor = makeAdvisor
    }

    nonisolated static func systemAdvisor() -> (any StepCheckModelAdvisor)? {
        #if canImport(FoundationModels)
        FoundationModelsStepCheckAdvisor()
        #else
        nil
        #endif
    }

    var isRunning: Bool { task != nil }

    /// Starts the advisor on the check that just finished. Returns at once.
    func start(
        outcome: VLMStepCheckService.Outcome,
        captureID: UUID,
        step: AuthoredStep,
        recorder: RecoveryEvidenceRecorder
    ) {
        cancel()
        let primary = CheckVerdictV1(rawValue: outcome.result.rawValue) ?? .uncertain
        let target = outcome.variant.checkTarget
        let box = outcome.checkGeometry?.deltaBox
        let advisor = makeAdvisor()
        let input = outcome.photoJPEG.flatMap { photo in
            outcome.targetJPEG.map { target in
                StepCheckAdviceInput(
                    photoJPEG: photo, targetJPEG: target, deltaBox: box,
                    targetIsRegistered: outcome.variant.checkTarget == .registered, stepNumber: step.index
                )
            }
        }
        task = Task {
            let advice: StepCheckAdvice
            if let advisor, let input {
                advice = await advisor.advise(input)
            } else {
                advice = .skipped(advisor == nil ? "unavailable_advisor" : "skipped_no_images")
            }
            guard !Task.isCancelled else { return }
            await recorder.recordShadowCheck(ShadowCheckTraceV1(
                sessionID: recorder.sessionID, captureID: captureID, stepIndex: step.index - 1,
                advisor: "foundation_models", checkTarget: target.rawValue,
                primaryVerdict: primary.rawValue, standaloneVerdict: advice.standalone?.rawValue,
                standaloneOutcome: advice.standaloneOutcome, closedAnswer: advice.closed?.rawValue,
                closedOutcome: advice.closedOutcome, mergedVerdict: ShadowMerge.merge(primary: primary, advice: advice).rawValue,
                hadDeltaBox: box != nil, latencyMilliseconds: advice.milliseconds,
                osBuild: DeviceIdentity.osBuild, deviceModel: DeviceIdentity.modelIdentifier, createdAt: .now
            ))
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// Waits for a running advisor to finish and record, up to `deadline`;
    /// past it the run is cancelled and records nothing. Returns at the
    /// deadline even if a model call ignores cancellation, so finalizing a
    /// session never hangs on the shadow.
    func drain(deadline: Duration) async {
        guard let running = task else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(continuation)
            Task { @MainActor in
                await running.value
                once.resume()
            }
            Task { @MainActor in
                try? await Task.sleep(for: deadline)
                running.cancel()
                once.resume()
            }
        }
        if task == running { task = nil }
    }
}

/// Resumes a continuation the first time only, from whichever task gets
/// there first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }
}
