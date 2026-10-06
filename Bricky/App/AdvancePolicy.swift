import Foundation

/// What the user asked for when they said or tapped "next" (ADR 0016).
enum AdvanceRequest: String, Sendable {
    /// Go on, unless the check says this step is not done yet.
    case next
    /// Go on whatever the check says: the user overrides it (ADR 0001).
    case nextAnyway = "next_anyway"
}

enum AdvanceRefusal: String, Sendable, Equatable {
    /// No guide is on screen in the foreground, so nobody is there to
    /// confirm the step.
    case unattended
    /// Every step is already confirmed.
    case finished
    /// No model is open.
    case noSession = "no_session"
}

enum AdvanceDecision: Equatable, Sendable {
    /// Confirm the step on screen and move to the next one.
    case advance
    /// Move the view on without touching progress: the step on screen is
    /// not the next one to build.
    case browseForward
    /// The check says the step is not done: say why (and how to fix it,
    /// when there is a repair), and wait. Only "next anyway" goes on.
    case holdAndSpeak(RepairPlan?)
    case refuse(AdvanceRefusal)
}

/// Decides what "next" does (M2.8, ADR 0016). Pure, so every row is tested.
///
/// - Hands-free requests (voice, Siri) need someone at the guide; on-screen
///   taps are attended by construction.
/// - On a step the user browsed to, "next" only moves the view. Progress
///   never moves backward here (ADR 0001; recovery is the only rewind).
/// - On the next step to build, "next" goes on when the check says
///   complete, when it cannot tell, and when there is no check at all. The
///   check is advisory: abstaining is not a reason to hold.
/// - A check that says incomplete or misplaced holds "next" and says why.
///   "Next anyway" always goes on.
enum AdvancePolicy {
    static func decide(
        request: AdvanceRequest,
        source: BuildSessionController.ConfirmationSource,
        verdict: StepVerdict?,
        repair: RepairPlan? = nil,
        attended: Bool,
        cursorIsFrontier: Bool,
        finished: Bool
    ) -> AdvanceDecision {
        if source.isHandsFree, !attended { return .refuse(.unattended) }
        guard cursorIsFrontier else { return .browseForward }
        guard !finished else { return .refuse(.finished) }
        switch (request, verdict) {
        case (.nextAnyway, _):
            return .advance
        case (.next, .incomplete?), (.next, .misplaced?):
            return .holdAndSpeak(repair)
        case (.next, _):
            return .advance
        }
    }
}

extension BuildSessionController.ConfirmationSource {
    /// Requests that arrive without a tap on the step itself.
    var isHandsFree: Bool {
        switch self {
        case .voice, .appIntent: true
        case .guide, .arVerified, .photoCheck, .recovery: false
        }
    }
}
