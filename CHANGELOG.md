# Changelog

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
