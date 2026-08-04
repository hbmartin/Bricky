# ADR 0008: The full triad, with geometric-first step verification

- Status: Accepted (supersedes ADR 0004's recovery-only scope)
- Date: 2026-08-03

## Context

ADR 0004 confined vision to advisory recovery ranking. A verified survey of
the field (2026-08-03) changed the calculus: no shipping product combines AR
guidance, live step verification, and LDraw input; the closest prior art is an
unevaluated conference demo. Pure-VLM verification is unreliable — the closest
benchmark reports a 40.54% best F1 on assembly-state detection over *clean
rendered* images, with false-positive rates above 97%: a VLM asked "is this
correct?" says yes almost regardless of reality. The exact step delta,
however, is already known deterministically from the authored plan, and the
LiDAR floor (ADR 0012) guarantees scene depth.

## Decision

Verify each step geometrically. Render expected depth and mask for the
cumulative model at steps k and k−1 from the registered pose, and classify
the observed delta region against three hypotheses — complete, incomplete,
misplaced (including ±1-stud and 90°/180° lattice offsets) — from raw scene
depth aggregated over ~20–40 frames, with RGB color and contour support at
full camera resolution. Compute per-step detectability from the CAD delta
before claiming anything: strong deltas may be judged by depth alone,
marginal deltas require depth and RGB agreement, and undetectable deltas
(small plates, flush tiles) abstain loudly and route to the VLM advisory or
cloud assist (ADR 0011). Thresholds are asymmetric: ties never break toward
complete, and the false-complete rate is a first-class release gate.

The on-device VLM becomes an advisory second opinion, never the primary
verifier. The user always overrides and nothing auto-advances (ADR 0001).
Runtime admission (ADR 0003) gates only VLM features; geometric verification
works on VLM-rejected devices.

Occlusion and ghost rendering deliberately avoid the granted claim of
US11393153B2: the next-step ghost is a solid translucent render, never
wireframe-only, occluded by the standard ARKit scene mesh, with no
wireframe-to-phantom rendering switch on step completion.

## Consequences

Vision scope expands from "which step am I on" to "was this step done
right", but every verdict is grounded in authored geometry, honest about
detectability, and measured against a false-complete gate. ADR 0004's
constrained-output VLM machinery survives as the advisory and fallback layer.
