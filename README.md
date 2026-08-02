# Bricky

Bricky is an iOS 17 instruction guide and AR recovery helper for authored LDraw
models. Import an MPD or stepped LDR, align its 3D ghost with a physical build,
capture three guided views to recover the last completed step, then continue
through deterministic 3D and AR instructions.

## Product boundaries

- MPD and stepped LDR are the only instruction formats. PDF is never accepted.
- `STEP` / `ROTSTEP` authorship is authoritative; Bricky never synthesizes an
  assembly order.
- Recovery and step checking run privately on-device with a pinned MLX VLM.
- AR registration is manual and transient: place, translate, and yaw the ghost.
- Catalog, inventory, community, games, Mosaic, SetForge, subscriptions, and
  cloud inference are not part of this product.

## Architecture

- Native Swift parser/planner with MPD sections, submodel instantiation,
  transforms, BFC rendering, LPub camera state, provenance, and validation.
- RealityKit geometry buffers shared by guide previews, recovery boards, and AR.
- SwiftData metadata and model/image files in the new
  `BrickyInstructionsV1` Application Support namespace.
- Development-only [pyldraw3](https://github.com/hbmartin/pyldraw3) 1.5.0
  golden manifests and snapshots under `Tools/InstructionPipeline`.
- A narrow local `Packages/RecoveryMLX` package for the pinned VLM and guided
  output grammars; `MLXFoundationModels` is excluded.

See [CONTEXT.md](CONTEXT.md) and [the ADRs](docs/adr) for contracts, evidence,
release gates, and intentional exclusions.

## Build and test

Requirements: Xcode 16.4+ (Xcode 27 beta is also exercised), XcodeGen, iOS 17+,
and Python 3.12+ with `uv` for development parity.

```sh
xcodegen generate
xcodebuild -project 'Bricky the Brick Scanner.xcodeproj' -scheme Bricky \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  CODE_SIGNING_ALLOWED=NO -skipPackagePluginValidation test
```

AR recovery, the production VLM warm-up, memory admission, and performance gates
must be validated on physical iPhone/iPad hardware. The deterministic guide can
be developed in the simulator.

## Licenses

Bricky is all rights reserved. pyldraw3 is a GPL-3.0-or-later development-only
dependency and is not included in the app. The downloaded LDraw Parts Library
is attributed under CC BY 2.0/4.0 in `Bricky/Resources/LDRAW_ATTRIBUTION.txt`.
