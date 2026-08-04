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
