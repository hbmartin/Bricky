# ADR 0004: Vision is recovery-only and advisory

- Status: Superseded by ADR 0008 (2026-08-03)
- Date: 2026-08-02

## Context

The deterministic instruction plan already knows every valid state. Vision is
valuable for locating progress and checking a step, but not as a source of new
instructions or exact missing-part claims.

## Decision

Normalize orientation and run one bounded 1024×1024 comparison board per call.
Rank up to eight candidates, narrow hierarchically, compare finalists against
all three guided views, and aggregate rankings deterministically. Constrain
outputs to `matched|insufficient` plus slots A–H for recovery and
`complete|incomplete|uncertain` for step checking. Users may override every
estimate and advance after uncertainty.

## Consequences

No image or model leaves the device. Automatic set identification, synthesized
steps, missing-part diagnosis, and teardown repair remain outside v1.
