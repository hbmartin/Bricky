# ADR 0010: Recovery is geometric-first; the VLM estimator is the fallback

- Status: Accepted
- Date: 2026-08-03

## Context

Recovery ("which authored step does the physical build match?") and
registration share the same machinery once depth-ICP exists: fitting
candidate cumulative meshes to observed depth and ranking by fit quality
answers both questions. The hierarchical VLM estimator works but costs five
to eight 3-GB-class inferences per recovery and is unvalidated at scale.

## Decision

Recover geometrically first: fit candidate steps over the same
coarse-to-fine index schedule the VLM estimator uses, score each candidate
by two-sided coverage (model points explained by depth, and observed
above-plane depth explained by the model), and conclude when the leader's
margin is decisive. When the geometric pass is inconclusive — poor depth,
ambiguous symmetric builds, tiny models — fall back automatically to the
full, unchanged hierarchical VLM estimator with the guided three-view
capture UX. Every estimate records which method produced it, and both paths
emit the same benchmark rows (ADR 0007) so they are measured against the
same gates.

## Consequences

In good conditions recovery no longer requires loading the VLM at all, which
relaxes the memory pressure that admission (ADR 0003) exists to manage. Two
stacks exist, but only one is novel: the VLM path is frozen as-is and its
maintenance cost is carried deliberately as insurance.

## Amendment (2026-09-25): the VLM path is unfrozen under recorded variants

"Frozen as-is" kept the insurance path stable, but it also froze the
defects the iOS 27 roadmap found: the finalist vote counted repeated
letters, and the guided loop drops sampled tokens from the KV cache.
The rules are now:

- **The baseline stays reproducible.** The shipping default reproduces
  the pinned behaviour exactly. `RecoveryGuidedDecoder` in `legacy` mode
  is byte-identical to the pinned `GuidedGenerationLoop`, which
  `RecoveryDecoderParityTests` proves on the real weights, and `upstream`
  remains selectable to re-prove it after any pin bump.
- **Behaviour changes are named variants.** Every change to what the model
  sees or emits (feeding, slot uniqueness, probability scoring, slot
  order, board layout, labels, prompt, image size, check target) ships as
  a variant that the harness can select and that traces record.
- **A default flips only with both of:**
  - a paired Mac replay on the same bundles showing either an exact
    McNemar win at p < 0.05 on per-pass top-1, or no significant loss
    together with a ≥ 5% latency win — and no rise in the insufficient or
    false-complete rate;
  - device rows: Release build, arms interleaved, ≥ 8 repetitions, and
    cold, warm and sustained buckets.
- **Aggregation-only fixes may ship as defaults**, because they leave
  model input and output untouched. De-duplicating the vote is one.
- **This amendment is neutral on whether the VLM leaves the app.** That is
  decided at the Foundation Models shadow-test gate.

Measured on the pinned weights (Mac, synthetic board): legacy feeding
drops 3 sampled tokens per rank call. These are the opening quotes of the
`status` and `ranking` keys and the sampled token before a forced enum
tail. The slot letters themselves do reach the cache.

## Amendment (2026-09-25): geometric recovery is not gated on VLM admission

The recovery flow used to wait for VLM admission before anything, so the
primary path (geometric recovery) was unavailable whenever the VLM
fallback was: model not downloaded, rejected, or still warming. The part
pack is now the only hard requirement:

- **The flow runs in every admission state.** A banner states what is
  missing, and warm-up proceeds in the background once the camera runs.
- **`CompositeRecoveryEstimator` takes an optional fallback.** With no
  admitted VLM, an inconclusive depth fit returns `insufficient`, with
  cause `geometric_inconclusive_without_fallback` and method `geometric`,
  and the manual step picker takes over. With neither leg possible (no
  depth frame and no model), the estimator says so instead of inventing an
  estimate.

CONTEXT.md's "Geometric features are never admission-gated" is now true of
recovery as well as verification.


## Amendment (2026-10-05): a placement-consistency tie-break, default off

When the geometric ranking is inconclusive, `PlacementConsistencyScorer`
(M2.6) may break the tie before recovery falls through to the VLM. It
renders each placement from the steps around the leader alone at the
leader's solved pose, and asks which step the observed parts agree with:
- the ranking is by contradictions, then explained exceptions (one
  forgotten part that nothing observed rests on), then agreements;
- it abstains unless one step is strictly best, and whenever a part seen
  absent has a part seen in place resting on it;
- it runs only when the leader's fit is undisqualified, within the RMS
  bound, and scores at least 0.3.

A win reports medium certainty and the revision `depth-icp-geometric-v1+pcs1`.

It is off (`Configuration.consistencyTieBreak`). The synthetic recovery
suite measures both arms. On 2026-10-05 its leaders scored about 0.2 under
the synthetic sensor model, so the tie-break never ran and the arms were
equal. The flip follows this ADR's variant rule:
- a paired `compare_arms.py --primary session_top1` result on Mac replays of
  real bundles;
- then device rows.
