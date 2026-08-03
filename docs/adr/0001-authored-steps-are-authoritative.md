# ADR 0001: Authored steps are authoritative

- Status: Accepted
- Date: 2026-08-02

## Context

An instruction guide must preserve the model author's intended sequence. An
unstepped LDraw model contains geometry but no defensible assembly order.

## Decision

Accept MPD and LDR sources only when the root has explicit `STEP` or `ROTSTEP`
boundaries. Expand buildable submodel instances before their parent placement,
give each instantiated step a stable instance-path identity, and transform leaf
placements into one final-model coordinate frame. Treat an unstepped embedded
geometry section as an atomic custom part. Reject cycles, unresolved custom
references, unsafe paths, and configured resource limits.

## Consequences

Bricky never invents or repairs an instruction sequence. Recovery estimates and
step checks can only select or assess authored steps, and users always retain
the final choice.
