import Foundation
import simd

/// Derives a repair from measurements and authored placements only (M2.4).
/// Deterministic: the same verdict or diff always gives the same actions,
/// and no model is consulted. In-step only (ADR 0015): anything touching an
/// earlier step is withheld until cross-step repair is enabled.
enum RepairPlanner {
    /// What a plan may act on: the step under verification.
    struct Context: Sendable {
        let stepID: String
        let stepIndex: Int
        let added: [PlacementRef]
    }

    /// The step's authored additions, as repair targets.
    static func context(plan: InstructionPlan, step: AuthoredStep) -> Context {
        let lower = min(max(0, step.addedPlacementRange.lowerBound), plan.placementTimeline.count)
        let upper = min(max(lower, step.addedPlacementRange.upperBound), plan.placementTimeline.count)
        let stepIndex = plan.steps.firstIndex { $0.id == step.id } ?? max(0, step.index - 1)
        return Context(
            stepID: step.id,
            stepIndex: stepIndex,
            added: (lower..<upper).map { index in
                let placement = plan.placementTimeline[index]
                return PlacementRef(
                    placement: index, placementID: placement.id, stepIndex: stepIndex,
                    partReference: placement.partReference, colourCode: placement.colorCode
                )
            }
        )
    }

    /// From today's verifier: a whole-delta stud misplacement becomes one
    /// move per added part, back by the measured offset. Every other verdict
    /// has no repair to offer.
    static func plan(verdict: StepVerdict, context: Context, flags: RepairFeatureFlags = RepairFeatureFlags()) -> RepairPlan? {
        guard case .misplaced(let offset) = verdict, !context.added.isEmpty else { return nil }
        let correction = LatticeOffset(dx: -offset.x, dz: -offset.y)
        return RepairPlan(
            stepID: context.stepID,
            actions: context.added.map { .move($0, by: correction) },
            withheld: [],
            source: .stepVerdict
        )
    }

    /// From the build diff, behind `buildDiffInput` until the diff has
    /// authority: absent parts are added, displaced ones moved back, turned
    /// ones turned back, and wrong-colour ones swapped for the authored
    /// colour. Parts the diff could not see are withheld, never guessed;
    /// plate steps are never acted on.
    static func plan(diff: BuildDiff, context: Context, flags: RepairFeatureFlags) -> RepairPlan? {
        guard flags.buildDiffInput else { return nil }
        let byPlacement = Dictionary(uniqueKeysWithValues: context.added.map { ($0.placement, $0) })
        var actions: [RepairAction] = []
        var withheld: [WithheldAction] = []
        for observation in diff.observations {
            guard let ref = byPlacement[observation.placement] else {
                // Not this step's part: an earlier step's problem.
                continue
            }
            switch observation.state {
            case .present:
                continue
            case .colourMismatch:
                actions.append(.swapColour(ref, expected: ref.colourCode))
            case .absent:
                actions.append(.add(ref))
            // As CrossStepRepairPlanner.fix: an offset or turn that changes
            // nothing must not become "move" or "turn" wording.
            case .displaced(let offset) where !offset.isVertical && (offset.dx != 0 || offset.dz != 0):
                actions.append(.move(ref, by: LatticeOffset(dx: -offset.dx, dz: -offset.dz)))
            case .displaced:
                continue
            case .rotated(let turns) where ((turns % 4) + 4) % 4 != 0:
                actions.append(.rotate(ref, quarterTurns: (4 - ((turns % 4) + 4) % 4) % 4))
            case .rotated:
                continue
            case .notObservable:
                withheld.append(WithheldAction(action: .add(ref), reason: .notObservable))
            }
        }
        guard !actions.isEmpty || !withheld.isEmpty else { return nil }
        return RepairPlan(stepID: context.stepID, actions: actions, withheld: withheld, source: .buildDiff)
    }
}
