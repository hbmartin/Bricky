# Contributing to Bricky

Read [CONTEXT.md](CONTEXT.md) before changing the instruction, recovery, or
shipping contracts.

## Non-negotiable boundaries

- Accept authored MPD and stepped LDR only; never add PDF ingestion.
- Never infer missing steps or claim automatic AR registration.
- Keep all inference local and advisory; users may override every estimate.
- Keep Python and GPL pyldraw3 code outside the iOS target and bundle.
- Treat `../Lego_Assembly` as read-only.
- Do not open, migrate, alter, or delete legacy on-device stores/preferences.

## Workflow

1. Change the domain contract and parser/planner deliberately.
2. Add a focused MPD/LDR fixture for every syntax or failure case.
3. Regenerate the pyldraw3 golden corpus and review semantic drift.
4. Add native unit coverage and, for user flows, UI coverage.
5. Generate the Xcode project from `project.yml` and build on iOS 17.

```sh
cd Tools/InstructionPipeline
uv sync --frozen
uv run python generate_golden.py --ldraw-root /path/to/ldraw --check

cd ../..
xcodegen generate
xcodebuild -project 'Bricky the Brick Scanner.xcodeproj' -scheme Bricky \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  CODE_SIGNING_ALLOWED=NO -skipPackagePluginValidation test
```

MLX or AR changes also require physical-device benchmark rows. Do not lower an
admission threshold or add a custom Metal/TensorOps kernel without an Instruments
trace, representative benchmark, numerical tolerance, and end-to-end gain.
