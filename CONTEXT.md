# Bricky engineering context

Bricky is an iOS 27 instruction guide for user-authored LDraw instruction
models on LiDAR-equipped iPhones, with AR step guidance, geometric step
verification, and build recovery. It is not a catalog, inventory, social,
game, subscription, or set-identification product.

## Product loop

1. Import one `.mpd`, one stepped self-contained `.ldr`, or a folder containing
   a root `.ldr` and its sibling custom files.
2. Validate authored `STEP` / `ROTSTEP` boundaries and build one deterministic,
   recursively-instantiated instruction plan.
3. Place the model ghost manually on a horizontal AR plane (alignment); the
   depth-ICP tracker refines and holds the pose against LiDAR depth
   (registration, ADR 0009).
4. Build with cumulative 3D instructions and AR overlays. While registration
   is locked, each step is verified geometrically against its authored delta,
   with the local VLM as advisory second opinion (ADR 0008). The user
   confirms every step; nothing auto-advances.
5. When lost, recover: geometric multi-hypothesis fit first, the hierarchical
   VLM estimator as automatic fallback (ADR 0010). Estimates are advisory;
   the user confirms any step, including step zero.
6. When the local pipeline is uncertain, an opt-in cloud assist with a
   user-supplied API key may give a second opinion on one explicitly
   consented frame (ADR 0011).

PDF input, inferred/synthesized steps, automatic set identification, and
teardown diagnosis are outside the product boundary. Steps 3–6 describe the
triad program (ADRs 0008–0013): registration, verification, geometric
recovery, and cloud assist land milestone by milestone; the shipping behavior
until then is manual alignment plus VLM recovery and step checking.

## Glossary

- **Alignment** — the user's manual coarse ghost placement (`ARAlignment`).
  Transient, never persisted; now the initializer for registration.
- **Registration** — the continuously refined model-to-world pose from
  depth-ICP, with explicit quality states (locked, ambiguous, lost…).
  Supersedes alignment while locked. Never persisted.
- **Verification** — the geometric complete / incomplete / misplaced /
  uncertain judgment of the current step's exact delta. Advisory to the
  user; runs only while registration is locked.
- **Recovery** — estimating *which* authored step the physical build
  matches. Geometric-first, VLM fallback.
- **Step delta** — the exact placements a step adds:
  `plan.addedPlacements(for:)` over `AuthoredStep.addedPlacementRange` into
  `placementTimeline`. The unit of verification.
- **Detectability** — the per-step, pre-computed answer to "can LiDAR depth
  even see this delta?" (strong / marginal / undetectable). Undetectable
  deltas abstain and route to the VLM or cloud assist.
- **Admission** — the runtime resource gate for the on-device VLM only
  (ADR 0003). Geometric features are never admission-gated.

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
  `mlx-community/Qwen3-VL-4B-Instruct-4bit@2fd8dacbdb8f1e54b8c005f081ec5bf79c56376b`
  (ADR 0013). Asset sizes and SHA-256 hashes were captured from that pinned
  revision; the LFS hashes come from the Hugging Face tree API and the
  small-file hashes were computed locally from pinned-revision downloads.
  The pinned `mlx-swift-lm` commit registers `qwen3_vl` in its VLM factory.
- ⚠️ INFERRED — the release admission threshold starts conservatively at 5.5 GB
  live available memory. It must be replaced by measured worst-case peak plus
  25% from physical-device runs (with AR, scene mesh, ICP, and the warm VLM
  concurrent) before release.

## Runtime boundaries

- `Bricky/Domain` contains value contracts shared by import, guide, recovery,
  persistence, and benchmarks.
- `Bricky/Services/Instructions` owns parsing, planning, atomic import, immutable
  geometry buffers, RealityKit adaptation, and the verified part-pack install.
- `Bricky/Services/Recovery` owns transient alignment, guided capture, bounded
  comparison boards, admission, hierarchical estimation, and opt-in evidence
  recording (ADR 0007).
- `Bricky/Services/Registration` (triad) owns the depth-ICP tracker, surface
  sampling, and the shared expected-depth raster pass.
- `Bricky/Services/Verification` (triad) owns the geometric step verifier.
- `Packages/RecoveryMLX` is the narrow MLX dependency boundary. It maintains one
  shared load task and `ModelContainer`, serializes inference through an actor,
  and creates a fresh grammar matcher for each stateless call.
- SwiftData and files use the new `BrickyInstructionsV1` Application Support
  namespace. Legacy stores, defaults, and files are neither opened nor migrated.
- `../Lego_Assembly` is read-only input to the redesign. No build, test, or tool
  may write into it.

## Privacy and failure semantics

Instruction models and LDraw files never leave the device. Images never leave
the device without explicit action: the off-by-default developer evidence
toggle (ADR 0007) permits manual export of evidence bundles, and the opt-in
cloud assist (ADR 0011) sends a single frame only after per-image consent
with the user's own API key. Nothing else egresses. Import publishes only
after the full source closure parses and plans successfully. VLM features are
hidden behind runtime admission; the deterministic guide and geometric
features remain usable when admission is rejected. Alignment and registration
are transient and must be re-established after relaunch or unrecoverable
tracking loss.

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

# Synthetic RGB-D rows (registration + verification kinds) from a stepped model:
xcodebuild -project '../../Bricky the Brick Scanner.xcodeproj' -scheme SyntheticRGBD \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
SyntheticRGBD ../SyntheticScenes/fixtures/synthetic-tower/tower.ldr \
  --ldraw-root /path/to/ldraw --out synthetic.ndjson --seed 7
python3 score_results.py synthetic.ndjson --allow-small-corpus
```

## Release gates still requiring physical assets or devices

- 🔴 GAP — synthetic gates green in CI: registration convergence ≥95% with
  ≤3 mm / ≤2° error on the perturbation sweep, ambiguity recall ≥90%,
  verification false-complete rate ≤2% (reported first), per-class
  precision/recall ≥0.90/0.85 (strong detectability) and ≥0.80/0.70
  (marginal), undetectable-abstention ≥95%, uncertain-on-correct ≤15%.
- 🔴 GAP — physical corpus: ≥40 distinct staged fixtures across ≥6 legally
  usable authored models with lighting/angle/occlusion variation; registration
  error ≤5 mm against a jig; the synthetic verification gates re-met on
  device; median latencies ≤3 s verification, ≤8 s geometric recovery, ≤20 s
  composite recovery.
- 🔴 GAP — profile the production-sized warm-up while AR, scene mesh, and the
  ICP tracker are active on candidate devices, set the memory floor to
  worst-case peak plus 25%, and record the admitted hardware set.
