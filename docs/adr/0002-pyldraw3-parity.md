# ADR 0002: pyldraw3 defines development-time parity

- Status: Accepted
- Date: 2026-08-02

## Context

MPD sectioning, recursive occurrences, rotations, LPub state, provenance, BOMs,
bounds, and diagnostics have enough edge cases that an independent executable
specification is required.

## Decision

Pin `pyldraw3==1.5.0` / commit
`61ebb868f3899eb052522576b73677111828e828` in an isolated Python 3.12+ `uv`
tool. Normalize environment-specific versions and paths, check golden schema-v1
manifests and cumulative snapshots into the repository, and require semantic
parity from the native Swift parser. Retain GPL notices in tooling only; do not
copy Python or pyldraw3 source into the app or bundle.

## Consequences

Parser changes require golden regeneration and review. Shipping remains native,
offline, and accepts MPD/LDR directly.
