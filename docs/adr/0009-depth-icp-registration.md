# ADR 0009: Registration is depth-ICP with manual coarse init

- Status: Accepted (supersedes ADR 0005's manual-only stance)
- Date: 2026-08-03

## Context

ADR 0005 held that automatic registration of a shape-changing partial build
is a separate computer-vision problem. Two facts changed: the LiDAR floor
(ADR 0012) guarantees a depth map, and the app always knows the exact
cumulative CAD mesh for the current step. Learned 6-DoF pose networks were
considered and rejected: textureless objects are a documented failure mode of
the FoundationPose family, and no published result covers LEGO-class parts.

## Decision

Track the build with projective point-to-plane ICP against the smoothed
scene-depth map, fitting an oriented point sample of the cumulative snapshot
(area-weighted, ~3 mm spacing, capped) and re-fitting as steps confirm. The
solve is 4-DoF gravity-constrained (translation plus yaw) at roughly 10 Hz
with a small iteration budget, Huber weighting, and annealed correspondence
rejection. Registration states are explicit: unplaced, coarse, refining,
locked, ambiguous, lost. Locked requires bounded RMS residual, a minimum
inlier fraction, and a lattice margin — the cost ratio re-evaluated at
±8 mm stud-lattice shifts and, for near-square footprints, 90° yaw — so
stud-grid aliasing is detected instead of silently accepted. On first lock
the ghost is parented to an ARAnchor so ARKit absorbs world drift.

The existing manual ghost placement survives unchanged as the coarse
initializer and as the universal fallback; iOS 27 reference-object auto-init
is a spike-gated enhancement, not a dependency. Verification (ADR 0008) runs
only while registration is locked. Registration is never persisted; the
transiency rule of ADR 0005 carries forward.

## Consequences

Registration quality becomes user-visible state rather than an implicit
promise. The solver is CPU/simd only under ADR 0006's discipline; the single
Metal addition is a shared depth-raster render pass used by verification and
synthetic evaluation alike.
