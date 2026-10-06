# ADR 0018: The photo check's advisor is decided by device rows

- Status: Proposed. This is the decision memo's template; the decision
  waits for device data.
- Date: 2026-10-06

## Context

The photo step check asks the 3 GB Qwen3-VL model, which runs in-process
and needs the memory admission floor, whether a photo matches the step's
target (ADR 0008: advisory, never primary). The roadmap's question 3 asks:
if iOS 27's on-device system model, which runs outside the app's process
and costs no memory budget, judges these photos at least as safely, should
the VLM leave the step check, or leave the app entirely? The owner decided
on 2026-09-25 to answer it with data, after a shadow test.

Facts that shape the test:
- **Strengths and limits of the system model.** It takes images (27 SDKs
  only) and names what is in them, but it cannot reliably say where. Apple
  points to Vision and geometry for location.
- **Its failures are often silent.** It is not pinned (each OS build may be
  a different model), its guardrails change outside OS releases, and a
  string-mode refusal is ordinary text.
- **Where measurements come from.** This development Mac is an M2 Pro, not
  the iPhone 17 Pro's model tier. Whether Mac and phone run the same
  weights is unknown, so only rows from the phone count (owner decision,
  2026-10-06).
- **A first local look** (informational, two generated images): the
  standalone verdict was right, and the closed question said "present" for
  a part that was not there. One toy case proves nothing, but it is the
  failure the device rows must measure.

## Decision (Proposed)

**The seam exists; the authority does not move.** `StepCheckAdvisor` is
the protocol a photo check answers through. The VLM answers through it,
and its verdict is the only one shown. "None" is the existing admission
gate: no admitted VLM, no photo check.

**The shadow test.** With evidence capture on and the developer setting
"Second opinion on photo checks, recorded only", each AR Photo Check also
runs `FoundationModelsStepCheckAdvisor` after the VLM returns:
- **Standalone.** Photo against target, "complete, incomplete or
  uncertain?" This is the VLM's own question, so the two can be compared
  directly.
- **Closed question.** When the check has a delta box (ADR 0007
  amendment 3), the photo and the registered render, both cropped to the
  box: "is this step's part in place?" Geometry chose the crop.
- **Merge.** The merged verdict may only turn a complete into an
  incomplete (`ShadowMerge`). The advisor never makes anything complete.
- **Recording.** Each run is kept in `shadow-checks.ndjson`. Labeled
  sessions also write scored `shadow_check` rows.

**What decides "the VLM leaves the step check".** All of the following
must hold, on staged device rows from floor devices, per OS build:
1. **Safety.** The advisor's standalone false-complete rate has a one-sided
   95% upper bound of at most 2%. With no misses, that takes at least 149
   negatives; the scorer prints how many more are still needed.
2. **No paired loss.** The advisor's standalone verdicts against the VLM's,
   on the same checks: `compare_arms.py --primary check_correct`, an exact
   McNemar test, with no loss in recall on complete steps.
3. **Cost.** Latency and thermal state with AR running are no worse in the
   sustained bucket.

**What decides "the VLM leaves the app"** is a separate decision. Recovery
still uses the VLM as its fallback ranker. The system model has not been
tested for ranking and will not be until the step-check decision is made.

**Mac replays** (`bricky-harness fm-shadow`) are for prompt work only. They
are labelled `replay`, and release mode refuses them.

## Consequences

- With the setting off, nothing changes.
- With it on, the user sees exactly what they saw before. The cost is a
  second model call after each AR photo check, out of process, and a few
  lines of evidence.
- The memo is completed, and this ADR's status changes, when the device
  rows meet the criteria above or clearly fail them. A failure keeps the
  VLM.
- Private Cloud Compute is not an option for a second provider here: the
  owner is not eligible (ADR 0011 note).
