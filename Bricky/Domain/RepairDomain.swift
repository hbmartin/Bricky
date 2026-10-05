import Foundation
import simd

/// One authored placement a repair acts on. Repairs only ever name authored
/// placements (ADR 0001, ADR 0015): they never invent a part or a step.
struct PlacementRef: Hashable, Sendable {
    /// Index into the plan's placement timeline.
    let placement: Int
    let placementID: String
    /// Plan index of the step that adds it.
    let stepIndex: Int
    let partReference: String
    let colourCode: Int
}

/// One deterministic repair step, derived from authored placements and the
/// measured diff only. Geometry measures; wording comes later and never
/// changes an action.
enum RepairAction: Hashable, Sendable {
    /// Place a part that is missing.
    case add(PlacementRef)
    /// Move a part by whole studs (x, z) to where it was authored.
    case move(PlacementRef, by: LatticeOffset)
    /// Turn a part about its own centre, in quarter turns.
    case rotate(PlacementRef, quarterTurns: Int)
    /// Swap for the authored colour (needs the RGB term; never from depth).
    case swapColour(PlacementRef, expected: Int)
    /// Take a part off (cross-step plans only, behind a flag).
    case remove(PlacementRef)
    /// Put a removed part back (cross-step plans only, behind a flag).
    case reAdd(PlacementRef)

    var target: PlacementRef {
        switch self {
        case .add(let ref), .move(let ref, _), .rotate(let ref, _), .swapColour(let ref, _),
             .remove(let ref), .reAdd(let ref):
            ref
        }
    }

    var name: String {
        switch self {
        case .add: "add"
        case .move: "move"
        case .rotate: "rotate"
        case .swapColour: "swap_colour"
        case .remove: "remove"
        case .reAdd: "re_add"
        }
    }
}

/// Why an action that would help is not offered.
enum WithholdReason: String, Hashable, Sendable {
    /// It touches an earlier step; cross-step repair waits for ADR 0015.
    case crossStepDisabled = "cross_step_disabled"
    /// The diff could not see the placement.
    case notObservable = "not_observable"
    /// The evidence contradicts how parts can physically rest.
    case implausible
    /// More parts would have to come off than a repair may ask.
    case removalBudgetExceeded = "removal_budget_exceeded"
}

struct WithheldAction: Hashable, Sendable {
    let action: RepairAction
    let reason: WithholdReason
}

struct RepairPlan: Hashable, Sendable {
    enum Source: String, Hashable, Sendable {
        /// From today's verifier verdict (whole-delta misplacement).
        case stepVerdict = "step_verdict"
        /// From the per-placement build diff (behind a flag until M2.3 flips).
        case buildDiff = "build_diff"
    }

    let stepID: String
    let actions: [RepairAction]
    let withheld: [WithheldAction]
    let source: Source
}

/// The screen's rotation relative to the camera sensor's native
/// landscape-right frame, without UIKit.
enum ScreenRotation: Int, CaseIterable, Sendable {
    case landscapeRight = 0
    case portrait = 90
    case landscapeLeft = 180
    case portraitUpsideDown = 270

    /// Screen right and screen up, in ARKit camera coordinates (+x right and
    /// +y up in landscape-right).
    var screenAxesInCamera: (right: SIMD3<Float>, up: SIMD3<Float>) {
        switch self {
        case .landscapeRight: (SIMD3(1, 0, 0), SIMD3(0, 1, 0))
        case .portrait: (SIMD3(0, 1, 0), SIMD3(-1, 0, 0))
        case .landscapeLeft: (SIMD3(-1, 0, 0), SIMD3(0, -1, 0))
        case .portraitUpsideDown: (SIMD3(0, -1, 0), SIMD3(1, 0, 0))
        }
    }
}

/// Where a correction points, said from where the user stands, or on the
/// screen when the camera looks nearly straight down.
enum RelativeDirection: String, Hashable, Sendable, CaseIterable {
    case awayFromYou = "away_from_you"
    case towardYou = "toward_you"
    case yourLeft = "your_left"
    case yourRight = "your_right"
    case screenUp = "screen_up"
    case screenDown = "screen_down"
    case screenLeft = "screen_left"
    case screenRight = "screen_right"
}

/// Repair behaviour that is not yet on. Cross-step plans wait for ADR 0015's
/// amendment; diff-driven plans wait for the build diff's authority flip.
struct RepairFeatureFlags: Hashable, Sendable {
    var crossStep = false
    var buildDiffInput = false
}
