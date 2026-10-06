import AppIntents
import Foundation

/// "Next step" from Siri or Shortcuts (M2.8b, ADR 0016). It runs without
/// opening Bricky, so it acts only while a build guide is on screen, and it
/// always asks before anything moves.
struct NextStepIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Build Step"
    static let description = IntentDescription(
        "Marks the step on screen in Bricky's build guide as done and shows the next one. Bricky asks first."
    )
    /// Never opens the app: with no guide on screen there is nobody to
    /// confirm the step, and the intent refuses.
    static let supportedModes: IntentModes = .background

    @AppDependency private var session: BuildSessionController

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let reply = try await NextStepHandler(session: session).run { prompt in
            // Declining throws, so nothing after this runs.
            try await requestConfirmation(dialog: IntentDialog(stringLiteral: prompt))
        }
        // Already localized: the catalog lookup falls back to the text itself.
        return .result(dialog: IntentDialog(stringLiteral: reply))
    }
}

/// The intent's logic apart from the system's confirmation sheet, so it can
/// be tested: refuse when nobody is at the guide, say exactly what will
/// happen, and act only on the step the user agreed to.
@MainActor
struct NextStepHandler {
    let session: BuildSessionController

    /// What Siri says at the end. `confirm` shows the prompt and throws when
    /// the user declines.
    func run(confirm: (String) async throws -> Void) async throws -> String {
        let preview = session.previewAdvance(.next, source: .appIntent, verification: session.reportedVerification)
        let request: AdvanceRequest
        let prompt: String
        switch preview {
        case .refuse(let reason):
            return StepNarration.refusal(reason)
        case .advance:
            request = .next
            prompt = advancePrompt()
        case .browseForward:
            request = .next
            prompt = String(localized: "Show step \(min(session.cursorIndex + 2, session.plan?.steps.count ?? 0))?")
        case .holdAndSpeak(let repair):
            // The check says the step is unfinished: confirming here is the
            // user's "next anyway", said with the reason in front of them.
            request = .nextAnyway
            let reason = session.reportedRepairSentence
                ?? repair.flatMap { RepairPhrasebook.sentence(for: $0.actions, direction: nil, labels: [:]) }
                ?? String(localized: "This step doesn't look complete yet.")
            prompt = reason + " " + String(localized: "Go on anyway?")
        }
        let agreedStep = session.cursorStep?.id
        try await confirm(prompt)
        guard session.cursorStep?.id == agreedStep else {
            return String(localized: "The guide moved on, so nothing changed.")
        }
        switch session.requestAdvance(request, source: .appIntent, verification: session.reportedVerification) {
        case .advance, .browseForward:
            if session.isFinished, session.cursorStep?.id == agreedStep {
                return StepNarration.buildFinished
            }
            return StepNarration.announcement(
                stepNumber: session.cursorIndex + 1, stepCount: session.plan?.steps.count ?? 0, partLabels: []
            )
        case .holdAndSpeak:
            // The check turned negative while the user was deciding.
            return StepNarration.hold(repairSentence: session.reportedRepairSentence)
        case .refuse(let reason):
            return StepNarration.refusal(reason)
        }
    }

    private func advancePrompt() -> String {
        let number = session.cursorIndex + 1
        let count = session.plan?.steps.count ?? 0
        return number >= count
            ? String(localized: "Mark step \(number) done and finish the build?")
            : String(localized: "Mark step \(number) done and show step \(number + 1)?")
    }
}

struct BrickyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NextStepIntent(),
            phrases: [
                "Next step in \(.applicationName)",
                "\(.applicationName) next step",
            ],
            shortTitle: "Next Step",
            systemImageName: "chevron.forward"
        )
    }
}
