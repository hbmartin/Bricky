import Foundation

/// Plans the fix for a problem in an earlier step's part that later parts
/// now rest on (M2.9, ADR 0015 cross-step section, Proposed). It acts on
/// authored placements and never invents or reorders the sequence:
/// 1. take off everything resting on the part, directly or through others,
///    in reverse authored order (top down);
/// 2. fix the part;
/// 3. put each one back in authored order.
///
/// Deterministic, from the support graph and the diff only. Off unless
/// `RepairFeatureFlags.crossStep` is set, which only tests and the tool do;
/// with it off, the fix is withheld.
enum CrossStepRepairPlanner {
    static let defaultBudget = 6

    /// - Parameters:
    ///   - anomaly: the diff's finding for the earlier part.
    ///   - observed: other placements the diff judged, for plausibility.
    ///   - built: placements physically expected so far (a timeline
    ///     prefix). Parts after it are not on the build and never move.
    ///   - budget: the most parts a repair may ask the user to take off.
    static func plan(
        anomaly: PlacementObservation,
        observed: [PlacementObservation] = [],
        index: PlacementGeometryIndex,
        plan: InstructionPlan,
        currentStepID: String,
        built: Int,
        budget: Int = defaultBudget,
        flags: RepairFeatureFlags
    ) -> RepairPlan? {
        let built = min(built, plan.placementTimeline.count, index.supports.count)
        guard (0..<built).contains(anomaly.placement),
              let target = ref(anomaly.placement, plan: plan),
              let fix = fix(for: anomaly.state, target: target) else { return nil }

        func withheld(_ reason: WithholdReason) -> RepairPlan {
            RepairPlan(stepID: currentStepID, actions: [], withheld: [WithheldAction(action: fix, reason: reason)], source: .buildDiff)
        }
        guard flags.crossStep else { return withheld(.crossStepDisabled) }

        let dependents = index.blockers(of: anomaly.placement).filter { $0 < built }
        // A part seen in place cannot rest on one that is missing: the pose
        // or the evidence is wrong, so nothing is asked of the user.
        let present = Set(observed.filter { $0.state == .present }.map(\.placement))
        if anomaly.state == .absent, dependents.contains(where: present.contains) {
            return withheld(.implausible)
        }
        guard dependents.count <= budget else { return withheld(.removalBudgetExceeded) }

        let refs = dependents.compactMap { ref($0, plan: plan) }
        guard refs.count == dependents.count else { return nil }
        let actions = refs.reversed().map(RepairAction.remove) + [fix] + refs.map(RepairAction.reAdd)
        return RepairPlan(stepID: currentStepID, actions: actions, withheld: [], source: .buildDiff)
    }

    /// The action that puts the part back as authored, or nil when the diff
    /// gives nothing to act on (present, a plate step, colour, unseen).
    static func fix(for state: PlacementState, target: PlacementRef) -> RepairAction? {
        switch state {
        case .absent:
            return .add(target)
        case .displaced(let offset) where !offset.isVertical && (offset.dx != 0 || offset.dz != 0):
            return .move(target, by: LatticeOffset(dx: -offset.dx, dz: -offset.dz))
        case .rotated(let turns) where ((turns % 4) + 4) % 4 != 0:
            return .rotate(target, quarterTurns: (4 - ((turns % 4) + 4) % 4) % 4)
        case .present, .displaced, .rotated, .colourMismatch, .notObservable:
            return nil
        }
    }

    /// An authored placement as a repair target, with the step that adds it.
    static func ref(_ placement: Int, plan: InstructionPlan) -> PlacementRef? {
        guard plan.placementTimeline.indices.contains(placement),
              let stepIndex = plan.steps.firstIndex(where: {
                  $0.addedPlacementRange.lowerBound <= placement && placement < $0.addedPlacementRange.upperBound
              }) else { return nil }
        let authored = plan.placementTimeline[placement]
        return PlacementRef(
            placement: placement, placementID: authored.id, stepIndex: stepIndex,
            partReference: authored.partReference, colourCode: authored.colorCode
        )
    }
}
