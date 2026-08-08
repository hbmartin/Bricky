# Changelog

## Unreleased — Corpus provenance and regression gating

- Recovery estimates now record which pipeline produced them
  (`geometric` / `composite` / `vlm`), and the composite estimator owns the
  wall clock across both legs. The scorer buckets latency on that field
  instead of inferring it from a model revision the row schema never carried,
  which had made the geometric latency gate unreachable and the composite gate
  measure only the VLM half.
- Geometric recovery attempts are recorded as Fit Records (`fits.ndjson`),
  including the coverage terms and disqualification reasons that were
  previously destroyed in memory. The primary recovery path had been leaving
  no evidence at all.
- Evidence sessions retain the recovery depth frame, the one bundle input that
  cannot be reconstructed later (ADR 0007 amendment).
- CI blocks on solver regressions against a committed baseline, separately
  from the release-gate scoring that stays informational until the sensor
  model is calibrated. Nothing previously protected the false-complete rate.
- Added the sensor-model fitting tool and its calibration plan (ADR 0014).
  The constants themselves are **not** yet calibrated.

## 2.0.0 — Instruction recovery rebuild

- Replaced the catalog-manager navigation and data model with Library, Recovery,
  Guide, and Storage experiences.
- Added native authored MPD/stepped-LDR parsing, deterministic recursive guide
  planning, immutable LDraw geometry, RealityKit previews, and manual AR
  alignment.
- Added three-view, hierarchical, grammar-constrained on-device MLX recovery and
  advisory step checking with explicit admission and user override.
- Added isolated pyldraw3 1.5.0 parity tooling, checked golden manifests and
  cumulative snapshots, native parity tests, and CI drift checks.
- Added the physical-device recovery evaluation harness and release metrics.
- Removed legacy catalog, inventory, community, game, Mosaic, SetForge,
  subscription, cloud-inference, proxy/backend, and bundled model/dataset code.
- Preserved Bricky's bundle identity and left all legacy on-device files and
  preferences untouched.
