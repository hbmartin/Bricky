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
5. Generate the Xcode project from `project.yml` and build on iOS 27. This
   requires Xcode 27 with the iOS 27 simulator runtime installed (the
   command below uses the iPhone 17 Pro simulator).

```sh
cd Tools/InstructionPipeline
uv sync --frozen
uv run python generate_golden.py --ldraw-root /path/to/ldraw --check

cd ../..
xcodegen generate
xcodebuild -project 'Bricky the Brick Scanner.xcodeproj' -scheme Bricky \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO -skipPackagePluginValidation test
```

MLX or AR changes also require physical-device benchmark rows. Produce them by
enabling the developer evidence toggle (ADR 0007), exporting an evidence
bundle, and replaying it with `bricky-harness` so device and Mac numbers share
the `RecoveryBenchmarkV1` format; prompt or board-layout changes additionally
require a baseline-vs-variant A/B replay of the same bundle. Do not lower an
admission threshold or add a custom Metal/TensorOps kernel without an Instruments
trace, representative benchmark, numerical tolerance, and end-to-end gain.

AR ghost rendering carries a deliberate design-around of US11393153B2
(ADR 0008): the next-step ghost is always a solid translucent render occluded
by the standard ARKit scene mesh. Do not introduce a wireframe-only ghost
style, a depth-only "phantom" occluder proxy of the built model, or a
rendering-mode switch triggered by step-completion detection — reviewers
should reject any of the three on sight.

## Agent skills

Installed skill copies (`.claude/skills/`, `.agents/skills/`) are not
committed; `skills-lock.json` is the source of truth. The lock records no
commit or tag, so on a clean install `computedHash` is the content lock:
after reinstalling with the Skills CLI, verify each installed skill hashes
to its `computedHash` entry and treat any mismatch as a failed install —
re-vendor the skill deliberately instead of trusting whatever the source
branch currently serves.
