# Bricky engineering context

Bricky is an iOS 17 instruction guide and AR recovery helper for user-authored
LDraw instruction models. It is not a catalog, inventory, social, game,
subscription, or set-identification product.

## Product loop

1. Import one `.mpd`, one stepped self-contained `.ldr`, or a folder containing
   a root `.ldr` and its sibling custom files.
2. Validate authored `STEP` / `ROTSTEP` boundaries and build one deterministic,
   recursively-instantiated instruction plan.
3. Place the model ghost manually on a horizontal AR plane and capture guided
   left, center, and right views.
4. Use the pinned local MLX VLM to rank authored candidate steps. The estimate
   is advisory; the user confirms any step, including step zero.
5. Continue with cumulative 3D instructions and optional AR overlays.

PDF input, inferred/synthesized steps, automatic set identification, automatic
AR registration, cloud inference, and teardown diagnosis are outside the
product boundary.

## Source of truth

- ✅ VERIFIED — `hbmartin/pyldraw3` 1.5.0 at commit
  `61ebb868f3899eb052522576b73677111828e828` is the development/CI semantic
  oracle. It is GPL-3.0-or-later and never ships in the iOS application.
- ✅ VERIFIED — the native Swift parser and planner are the shipping runtime.
  `Tools/InstructionPipeline` regenerates normalized schema-v1 manifests and
  cumulative snapshots for parity tests.
- ✅ VERIFIED — the LDraw 2026-07 archive identity is exactly 144,722,356 bytes
  and SHA-256 `6009f2e94204c4d3a63a4c812010b5c90bad8c5acb19b882c859fdac63734eae`.
- ✅ VERIFIED — that archive and its pyldraw3 1.5.0 manifest are published as
  the immutable `hbmartin/Bricky` GitHub Release `ldraw-2026-07`; the app and CI
  consume the exact pinned asset URL.
- ✅ VERIFIED — recovery uses model revision
  `mlx-community/Qwen2.5-VL-3B-Instruct-4bit@46d4cf06a06ffc1a766c214174f9cbed2f45bcab`.
- ⚠️ INFERRED — the release admission threshold starts conservatively at 5.5 GB
  live available memory. It must be replaced by measured worst-case peak plus
  25% from physical-device runs before release.

## Runtime boundaries

- `Bricky/Domain` contains value contracts shared by import, guide, recovery,
  persistence, and benchmarks.
- `Bricky/Services/Instructions` owns parsing, planning, atomic import, immutable
  geometry buffers, RealityKit adaptation, and the verified part-pack install.
- `Bricky/Services/Recovery` owns transient alignment, guided capture, bounded
  comparison boards, admission, hierarchical estimation, and opt-in evidence
  recording (ADR 0007).
- `Packages/RecoveryMLX` is the narrow MLX dependency boundary. It maintains one
  shared load task and `ModelContainer`, serializes inference through an actor,
  and creates a fresh grammar matcher for each stateless call.
- SwiftData and files use the new `BrickyInstructionsV1` Application Support
  namespace. Legacy stores, defaults, and files are neither opened nor migrated.
- `../Lego_Assembly` is read-only input to the redesign. No build, test, or tool
  may write into it.

## Privacy and failure semantics

Instruction models and images never leave the device automatically; the
off-by-default developer evidence toggle (ADR 0007) permits explicit, manual
export of recovery evidence bundles through the share sheet, and nothing else
egresses. Import publishes only after the full source closure parses and plans
successfully. Recovery is hidden behind runtime admission and has no cloud or
manual-inference fallback; the deterministic guide remains usable when
recovery is rejected. Alignment is transient and must be repeated after
relaunch or unrecoverable tracking loss.

## Evidence vocabulary (ADR 0007)

- **Evidence Trace** — the full record of one VLM inference call: prompt,
  grammar schema, raw model output, decode error, termination, latency, and
  memory footprint, plus the board and per-candidate tile images it saw. One
  NDJSON row in a session's `traces.ndjson`.
- **Evidence Session** — one recovery run's traces, image copies, ground
  truth, and estimate summary under `Evidence/<session>/`. Sessions are
  copies; they never own recovery work files.
- **Evidence Bundle** — the versioned zip a user explicitly exports from the
  Developer section. Its directory layout is the interchange format consumed
  by `bricky-harness` and Python tooling.
- **Staged Fixture** — a corpus-collection session whose expected step and
  conditions (lighting, occlusion, physical case, legal use) were declared
  before capture. Produces a fully-populated `RecoveryBenchmarkV1` row.
- **Ground truth kinds** — `staged` (declared up front), `confirmed` (labeled
  by the user's Confirm action after a real recovery), `unlabeled` (failures
  and abandoned sessions, kept deliberately).

## Verification commands

```sh
xcodegen generate
xcodebuild -project 'Bricky the Brick Scanner.xcodeproj' -scheme Bricky \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO \
  -skipPackagePluginValidation build

cd Tools/InstructionPipeline
uv sync --frozen
uv run python generate_golden.py --ldraw-root /path/to/ldraw --check

cd ../RecoveryEvaluation
python3 score_results.py device-results.ndjson
```

## Release gates still requiring physical assets or devices

- 🔴 GAP — collect at least 150 cases across at least 10 legally usable authored
  models and meet ≥95% top-three, ≥80% top-one, and ≤20 s median recovery.
- 🔴 GAP — profile the production-sized warm-up while AR is active on candidate
  devices, set the memory floor to worst-case peak plus 25%, and record the
  admitted hardware set.
