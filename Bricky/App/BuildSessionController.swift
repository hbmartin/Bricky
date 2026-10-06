import Foundation
import Observation
import SwiftData

/// Anything that can load an imported model's authored plan.
@MainActor
protocol PlanLoading {
    func loadPlan(for model: StoredInstructionModel) throws -> InstructionPlan
}

extension InstructionLibraryController: PlanLoading {}

/// The one owner of build progress: which model is open, which step the
/// user is looking at, and how many steps they have completed.
///
/// Progress used to live in four places — `@State` in GuideView and
/// ARGuideView, plus direct writes from StepCheckView and the recovery
/// flow — each saving on its own with `try? context.save()`. A change made
/// in one (a confirm in AR, a recovered step) reached the others only by
/// luck of reload timing, and a voice or Siri command could not have
/// updated the screen at all. Every progress change now goes through here,
/// records where it came from, and surfaces a failed save.
@MainActor
@Observable
final class BuildSessionController {
    /// Where a confirmation came from. Every advance traces to an explicit
    /// user act (ADR 0001: the user confirms every step).
    enum ConfirmationSource: String, Sendable {
        case guide
        case arVerified = "ar_verified"
        case photoCheck = "photo_check"
        case recovery
        case voice
        case appIntent = "app_intent"
    }

    private(set) var model: StoredInstructionModel?
    private(set) var plan: InstructionPlan?
    /// The step being shown, as an index into `plan.steps`. Browsing moves
    /// it without saving anything.
    private(set) var cursorIndex = 0
    private(set) var lastConfirmationSource: ConfirmationSource?
    /// The last save failure, so the UI can say progress was not stored
    /// rather than silently losing it.
    private(set) var lastPersistenceError: String?
    private var context: ModelContext?
    /// Guides on screen in the foreground: someone is there to confirm.
    private var attendingGuides: Set<String> = []

    var isAttended: Bool { !attendingGuides.isEmpty }
    private(set) var reportedVerification: StepVerification?
    private(set) var reportedRepairSentence: String?

    var cursorStep: AuthoredStep? {
        guard let plan, plan.steps.indices.contains(cursorIndex) else { return nil }
        return plan.steps[cursorIndex]
    }

    /// Authored steps completed and confirmed (0 = nothing built yet).
    var completedCount: Int { model?.currentStepIndex ?? 0 }

    var isFinished: Bool {
        guard let plan else { return false }
        return !plan.steps.isEmpty && completedCount >= plan.steps.count
    }

    /// Opens `model`, loading its plan the first time. Reopening the model
    /// already open keeps the browsing position, so returning from AR or a
    /// photo check does not snap the guide back.
    func open(_ model: StoredInstructionModel, loader: some PlanLoading, context: ModelContext) throws {
        self.context = context
        if self.model?.persistentModelID != model.persistentModelID || plan == nil {
            let loaded = try loader.loadPlan(for: model)
            self.model = model
            plan = loaded
            cursorIndex = Self.cursor(forCompleted: model.currentStepIndex, in: loaded)
        }
        model.lastOpenedAt = .now
        save()
    }

    func browse(by delta: Int) {
        guard let plan, !plan.steps.isEmpty else { return }
        cursorIndex = min(max(0, cursorIndex + delta), plan.steps.count - 1)
    }

    /// Records `step` as done and moves the cursor to the step after it.
    /// Progress only moves forward here: confirming a step the user browsed
    /// back to acts as browsing forward, so saved progress is never lost.
    /// Deliberate rewinds go through `setCompletedCount` (recovery).
    func confirm(_ step: AuthoredStep, source: ConfirmationSource) {
        guard let model, let plan else { return }
        let done = min(plan.steps.count, step.index)
        if done > model.currentStepIndex {
            model.confirmedLastCompletedStepID = step.id
            model.currentStepIndex = done
        }
        model.lastOpenedAt = .now
        lastConfirmationSource = source
        cursorIndex = Self.cursor(forCompleted: done, in: plan)
        save()
    }

    /// "Next" by voice or Siri, decided by `AdvancePolicy` and applied here
    /// (ADR 0016). `verification` counts only when it judged the step on
    /// screen. Holding or refusing changes nothing.
    @discardableResult
    func requestAdvance(
        _ request: AdvanceRequest, source: ConfirmationSource, verification: StepVerification?
    ) -> AdvanceDecision {
        let decision = previewAdvance(request, source: source, verification: verification)
        switch decision {
        case .advance:
            if let step = cursorStep { confirm(step, source: source) }
        case .browseForward:
            browse(by: 1)
        case .holdAndSpeak, .refuse:
            break
        }
        return decision
    }

    /// What `requestAdvance` would do now, changing nothing: Siri asks the
    /// user to confirm exactly this before anything moves.
    func previewAdvance(
        _ request: AdvanceRequest, source: ConfirmationSource, verification: StepVerification?
    ) -> AdvanceDecision {
        guard let plan, let step = cursorStep else { return .refuse(.noSession) }
        let verdict = verification?.stepID == step.id ? verification?.verdict : nil
        let repair = verdict.flatMap { RepairPlanner.plan(verdict: $0, context: RepairPlanner.context(plan: plan, step: step)) }
        return AdvancePolicy.decide(
            request: request,
            source: source,
            verdict: verdict,
            repair: repair,
            attended: isAttended,
            cursorIsFrontier: cursorIndex == Self.cursor(forCompleted: completedCount, in: plan),
            finished: isFinished
        )
    }

    /// The AR guide's latest check and its worded repair, so a request that
    /// arrives without a view (Siri) judges by what the screen shows.
    func reportVerification(_ verification: StepVerification?, repairSentence: String?) {
        reportedVerification = verification
        reportedRepairSentence = repairSentence
    }

    /// Marks a guide as on screen in the foreground (`true`) or not. A
    /// hands-free request is refused unless some guide is attending.
    func setAttending(_ attending: Bool, by guide: String) {
        if attending {
            attendingGuides.insert(guide)
        } else {
            attendingGuides.remove(guide)
        }
    }

    /// Sets progress outright (recovery: "I am at step N"), landing the
    /// cursor on the next step to build.
    func setCompletedCount(_ count: Int, source: ConfirmationSource) {
        guard let model, let plan else { return }
        let clamped = min(max(0, count), plan.steps.count)
        model.confirmedLastCompletedStepID = clamped == 0 ? nil : plan.steps[clamped - 1].id
        model.currentStepIndex = clamped
        model.lastOpenedAt = .now
        lastConfirmationSource = source
        cursorIndex = Self.cursor(forCompleted: clamped, in: plan)
        save()
    }

    /// Saves pending changes — progress and anything else the caller
    /// inserted into the same context — and records a failure.
    func save() {
        guard let context else { return }
        do {
            try context.save()
            lastPersistenceError = nil
        } catch {
            lastPersistenceError = "Progress could not be saved: \(error.localizedDescription)"
        }
    }

    /// The next step to build after `completed` steps, clamped to the last.
    static func cursor(forCompleted completed: Int, in plan: InstructionPlan) -> Int {
        min(max(0, completed), max(0, plan.steps.count - 1))
    }
}
