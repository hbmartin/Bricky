import Foundation
import RecoveryMLX
import UIKit

/// The on-device VLM step check, shared by the Check Step screen and the AR
/// guide's Photo Check. Its verdict is advisory (ADR 0008): the user decides
/// every advance.
///
/// What the model sees is a recorded variant (ADR 0010 amendment), the
/// check target included. The baseline compares the photo against the fixed
/// guide-camera render, as the check always has; `registered` renders the
/// target from the photo's own camera under the locked registration, which
/// only exists in AR. With evidence on, the target the call did not use is
/// rendered too and recorded beside it, so a replay can A/B the target on
/// identical photos.
@MainActor
struct VLMStepCheckService {
    struct Outcome {
        let result: StepCheckResult
        /// The exact board the model judged, kept so cloud assist shows and
        /// sends that image and no other (ADR 0011).
        let boardJPEG: Data
        /// The variant that actually ran; its check target is the one used.
        let variant: RecoveryInferenceVariant
    }

    let runtime: MLXRecoveryRuntime
    let modelDirectory: URL
    let partPackRoot: URL
    let variant: RecoveryInferenceVariant
    /// Present only when the developer evidence toggle is on; recording is a
    /// pure observer and never changes the verdict.
    let recorder: RecoveryEvidenceRecorder?

    /// Checks `capture` against the cumulative target for `step`.
    ///
    /// - Parameter registered: the locked registration's model pose, when
    ///   the check runs in AR. Without it only the guide camera exists, and a
    ///   variant asking for `registered` falls back to it — the recorded
    ///   variant then says so.
    func check(
        capture: RecoveryCapture,
        plan: InstructionPlan,
        step: AuthoredStep,
        registered: ARAlignment?
    ) async throws -> Outcome {
        await recorder?.recordCaptures([capture])
        let target = Self.resolvedTarget(requested: variant.checkTarget, registeredAvailable: registered != nil)
        var used = variant
        used.checkTarget = target
        let renderer = try InstructionSnapshotRenderer(plan: plan, partPackRoot: partPackRoot)
        let image = try await render(target, step: step, capture: capture, registered: registered, renderer: renderer)
        try Task.checkCancellation()
        let root = try InstructionModelImporter.applicationSupportRoot()
        let board = try RecoveryBoardComposer.composeCheck(
            physicalViewURL: root.appendingPathComponent(capture.imageRelativePath),
            target: (slot: "A", image: image, stepNumber: step.index),
            layout: used.boardLayout,
            labels: used.labels
        )
        defer { try? FileManager.default.removeItem(at: board) }
        let boardJPEG = try Data(contentsOf: board)
        let prompt = RecoveryPrompts.check(style: used.promptStyle, layout: used.boardLayout)
        let response = try await runtime.checkStepWithTrace(
            imageURL: board,
            prompt: prompt,
            modelDirectory: modelDirectory,
            decode: used.decode,
            scoring: used.scoring,
            imageSide: used.imageSide
        )
        if let recorder {
            // Rendered after inference so it never shares the GPU with the
            // model, and best-effort: a failed alternate costs the A/B one
            // row, never the check.
            var alternates: [CheckTarget: Data] = [:]
            for other in Self.alternateTargets(used: target, registeredAvailable: registered != nil) {
                if let rendered = try? await render(other, step: step, capture: capture, registered: registered, renderer: renderer),
                   let data = rendered.jpegData(compressionQuality: 0.9) {
                    alternates[other] = data
                }
            }
            // Runs before the defer removes the board, so the recorder can
            // copy the exact image the model saw.
            await recorder.recordPass(
                pass: .check,
                passIndex: 0,
                capture: capture,
                candidates: [.init(
                    slot: "A",
                    stepIndex: step.index - 1,
                    stepID: step.id,
                    jpegData: image.jpegData(compressionQuality: 0.9)
                )],
                boardURL: board,
                prompt: prompt,
                trace: response.trace,
                variant: used,
                alternateTiles: alternates
            )
        }
        guard let output = response.output else { throw MLXRecoveryError.invalidStructuredOutput }
        return Outcome(
            result: StepCheckResult(rawValue: output.result) ?? .uncertain,
            boardJPEG: boardJPEG,
            variant: used
        )
    }

    private func render(
        _ target: CheckTarget,
        step: AuthoredStep,
        capture: RecoveryCapture,
        registered: ARAlignment?,
        renderer: InstructionSnapshotRenderer
    ) async throws -> UIImage {
        switch (target, registered) {
        case (.registered, let alignment?):
            try await renderer.image(forStepIndex: step.index - 1, capture: capture, alignment: alignment)
        default:
            try await renderer.image(forStepIndex: step.index - 1)
        }
    }

    static func resolvedTarget(requested: CheckTarget, registeredAvailable: Bool) -> CheckTarget {
        requested == .registered && !registeredAvailable ? .guideCamera : requested
    }

    /// Every target the call could have used but did not.
    static func alternateTargets(used: CheckTarget, registeredAvailable: Bool) -> [CheckTarget] {
        CheckTarget.allCases.filter { $0 != used && (registeredAvailable || $0 != .registered) }
    }

    /// The label a finished check leaves on its evidence session. A staged
    /// declaration was made before the photo, so it labels the check
    /// whatever the user does next — which is what makes staged negatives
    /// (declared short of this step) possible at all. Without one, only
    /// "Confirm & Advance" after a complete verdict is a label.
    static func groundTruth(
        staged: StagedFixtureDeclaration?,
        plan: InstructionPlan,
        step: AuthoredStep,
        confirmed: Bool,
        at date: Date = .now
    ) -> EvidenceGroundTruth {
        if let staged {
            let count = staged.expectedCompletedCount
            return EvidenceGroundTruth(
                kind: .staged,
                expectedCompletedCount: count,
                expectedStepID: count == 0
                    ? plan.stepZeroID
                    : plan.steps.indices.contains(count - 1) ? plan.steps[count - 1].id : nil,
                confirmedCompletedCount: confirmed ? step.index : nil,
                confirmedAt: confirmed ? date : nil
            )
        }
        guard confirmed else { return .unlabeled }
        return EvidenceGroundTruth(
            kind: .confirmed,
            expectedCompletedCount: step.index,
            expectedStepID: step.id,
            confirmedCompletedCount: step.index,
            confirmedAt: date
        )
    }
}
