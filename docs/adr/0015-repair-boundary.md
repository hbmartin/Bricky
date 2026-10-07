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
  "found" or "locked on" (CONTRIBUTING). Amended 2026-10-06 (ADR 0017):
  behind an off-by-default developer setting, the on-device language model
  may reword a template. It is given the plan's facts and must repeat them;
  `RepairWordingValidator` rejects any sentence that adds a direction,
  number, colour, rotation sense or forbidden word, and the template is
  shown instead. No model decides what to do, which way, or how far.
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

### Cross-step planner (M2.9, Proposed, flag off)

`CrossStepRepairPlanner` is built and tested so the owner can judge
something concrete. It runs only with `RepairFeatureFlags.crossStep`, which
has no UI; with the flag off it withholds the fix (`cross_step_disabled`).
Given one earlier part the build diff found moved, turned or missing:
1. Take off everything resting on it, directly or through other parts, in
   reverse authored order. Authored order is a valid build order, so its
   reverse is a valid teardown. Only built parts count: later steps' parts
   are not on the build and never move.
2. Fix the part: add it, move it back by whole studs, or turn it back.
3. Put each removed part back in authored order.

It never asks for more than six parts off (`removal_budget_exceeded`). A
missing part with parts seen in place on top of it is `implausible`, as in
the recovery tie-break (ADR 0010): the pose or the evidence is wrong, so
nothing is asked.

`SyntheticRGBD --suite repair` adds cross-step rows on the challenge
fixture. Each plan is replayed on the support graph, and any step a builder
could not take, or a build left different from authored, counts as a
harmful action. The gate is 0.

## Consequences

- CONTEXT.md and ADR 0001 gain an in-step repair sentence. ADR 0004 (already
  superseded) gains a pointer here.
- "Brick looks misplaced by about one stud" is gone. A misplaced step now
  says which part to move, and which way when the direction is stable.
- `repair_plan` rows from `SyntheticRGBD --suite repair` guard the planner.
  A harmful action fails the run.
