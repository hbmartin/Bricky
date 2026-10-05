# ADR 0015: Repair is in-step and derived from authored placements

- Status: Accepted (in-step); cross-step part Proposed
- Date: 2026-10-05

## Context

Bricky matches a build against authored steps (ADR 0001). The verifier
(ADR 0008) could say a step's parts were "misplaced by about one stud", but
not which way. Real mid-build states are often one part off: shifted a stud,
turned the wrong way round, or missing.

The build diff (M2.3) can now name the placement and the offset. CONTEXT.md
and ADR 0004 placed "teardown diagnosis" and "missing-part diagnosis and
teardown repair" outside the product. The owner decided on 2026-09-25 that
repair starts within the current step, and that cross-step "remove and
re-add" plans wait for this ADR to say how.

## Decision

**In-step repair is accepted.** Inside the step under verification, Bricky
may say how to fix that step's parts: add a part, move it back by whole
studs, or turn it about its own centre. Rules:
- A repair is derived deterministically from measurements (verifier or
  build diff) and authored placements, by `RepairPlanner`. It acts only on
  authored placements of the current step and never invents a part, a step,
  or an order.
- Directions come from poses. A correction is carried into the world by the
  registered model pose and said relative to the user ("toward you", "to
  your right") from gravity-aligned camera axes, or in screen terms when the
  camera looks straight down. No model decides a direction or an offset.
- Wording comes from fixed templates in the String Catalog
  (`RepairPhrasebook`). The phrasebook never uses "automatic", "detected",
  "found" or "locked on" (CONTRIBUTING).
- Repairs are text only. Any AR arrow or overlay that points needs a
  US11393153B2 design-around review first (ADR 0008 note).
- Until the build diff has authority (ADR 0008 amendment), user-facing
  repairs come from the verifier's whole-delta misplacement only. Diff-driven
  plans exist behind `RepairFeatureFlags.buildDiffInput`.

**Cross-step repair is Proposed, not accepted.** That covers removing later
parts to fix a buried one, then re-adding them. A planner for it may be
built and tested behind `RepairFeatureFlags.crossStep`, which is off and has
no UI. If accepted, the wording is fixed: it "acts on authored placements,
never invents or reorders the sequence". It needs the owner's acceptance of
this section, and the amendments it would make to CONTEXT.md, ADR 0001 and
ADR 0004 are not made until then.

## Consequences

- CONTEXT.md and ADR 0001 gain an in-step repair sentence. ADR 0004 (already
  superseded) gains a pointer here.
- "Brick looks misplaced by about one stud" is gone. A misplaced step now
  says which part to move, and which way when the direction is stable.
- `repair_plan` rows from `SyntheticRGBD --suite repair` guard the planner.
  A harmful action fails the run.
