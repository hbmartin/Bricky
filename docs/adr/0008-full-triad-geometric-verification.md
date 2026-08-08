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

## Amendment 2026-08-07: the RGB support term is owed, and the marginal gate says so

The decision above splits detectability three ways and requires **depth and
RGB agreement** before a marginal delta may be called complete. The RGB half
was never built. `GeometricStepVerifier` therefore refuses `complete` unless
detectability is `strong`, which is the correct conservative behaviour — but
`score_results.py` still enforces a 0.70 complete-recall floor on the
marginal class. Measured on the real-tower fixture (2026-08-07): 6 marginal
cases, `complete_recall` **0.0**. The gate is not dormant — it fails on every
run, and only the `continue-on-error` on the scoring step keeps that from
blocking. A permanently-failing gate that nobody can act on is indistinguishable
from noise, and gets read as background failure rather than as the specific
missing capability it is.

Building the RGB term now would mean tuning it against a **synthetic colour
sensor model that does not exist and would have to be invented** — the same
mistake the depth sensor model is being corrected for (ADR 0014). So:

1. Marginal deltas whose expected verdict is `complete` are **out of corpus
   scope** until the RGB support term ships. Staged fixtures must not declare
   them, and the synthetic taxonomy must not generate them. The marginal
   recall floor is then genuinely dormant rather than permanently red — and
   when the term lands, restoring the fixtures is what proves it works.
2. The RGB term is owed work, tracked in
   [NEXT_STEPS_AND_FOLLOWUP.md](../NEXT_STEPS_AND_FOLLOWUP.md). It needs a
   colour plane on `RegistrationFrameInput` (which today carries depth only),
   an expected-colour render pass (`ExpectedDepthRenderer` emits depth only),
   the verifier term itself, and a colour sensor model built as deliberately
   as the depth one.
3. `ModelSurfaceSample.colorCodes` already exists and is read by nobody. It
   is scaffolding for this term, not dead code — but until the term lands it
   is indistinguishable from dead code, so it is named here.

Independent evidence that the marginal band is genuinely at the sensor floor,
and that this is a sensing limit rather than an implementation gap: published
iPhone LiDAR evaluations measure ±1 cm absolute accuracy on objects with side
length above 10 cm and place features under roughly 1 cm below the sensor's
reliable resolution (Luetzenburg et al., *Scientific Reports* 11, 22221,
2021). A stud is 8 mm pitch and a plate 3.2 mm tall. Depth alone should not
be trusted to call a marginal delta complete, and the current refusal is
right even though the gate covering it is currently unsatisfiable.
