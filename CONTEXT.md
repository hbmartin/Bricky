# Bricky engineering context

Bricky is an iOS 27 instruction guide for user-authored LDraw instruction
models on iPhone 17 Pro and iPhone 17 Pro Max (or a later Pro-class iPhone;
ADR 0012), with AR step guidance, geometric step verification, and build
recovery. It is not a catalog, inventory, social,
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
   and the user may ask the local VLM for an advisory photo check at the
   locked pose (ADR 0008). The user confirms every step; nothing
   auto-advances.
5. When lost, recover: geometric multi-hypothesis fit first, the hierarchical
   VLM estimator as automatic fallback when it is admitted and the device is
   cool enough (ADR 0010, ADR 0003). Estimates are advisory; the user
   confirms any step, including step zero.
6. When the local pipeline is uncertain, an opt-in cloud assist with a
   user-supplied API key may give a second opinion on one explicitly
   consented frame (ADR 0011).

PDF input, inferred/synthesized steps, automatic set identification, and
teardown diagnosis are outside the product boundary. Repair inside the
current step is in: a deterministic plan, derived from measurements and that
step's authored placements, says which part to add, move or turn, and which
way from where the user stands (ADR 0015). Cross-step "remove and re-add"
plans are proposed, not accepted. Steps 3–6 are built
(the triad program, ADRs 0008–0013), but none of their release gates has
device evidence yet: every rate and latency below is unmeasured on an
iPhone 17 Pro until the Phase 1 corpus exists ([IOS27_ROADMAP.md](docs/IOS27_ROADMAP.md)).
The VLM path changes only through recorded inference variants, and a
default flips only on a paired A/B (ADR 0010 amendment). Phase 3 added, all
off or in shadow behind developer settings: a non-learned colour check
beside the verifier (ADR 0008 amendment, Proposed), repair wording by the
on-device language model (ADR 0017), and a Foundation Models second opinion
on photo checks (ADR 0018, Proposed).

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
- **Composite recovery** — a recovery where the geometric pass ran, did not
  conclude, and the VLM estimator answered instead. Distinct from a recovery
  where no geometric pass was possible: both spend the inference budget, but
  only a composite also paid for the attempt that did not help. Every
  estimate names which of the three it was.
- **Step delta** — the exact placements a step adds:
  `plan.addedPlacements(for:)` over `AuthoredStep.addedPlacementRange` into
  `placementTimeline`. The unit of verification.
- **Detectability** — the per-step, pre-computed answer to "can LiDAR depth
  even see this delta?" (strong / marginal / undetectable). Undetectable
  deltas abstain and route to the VLM or cloud assist.
- **Device floor** — `DeviceFloor`, the single runtime gate for the whole
  app: LiDAR-class AR, an `iPhone<≥18>,<n>` identifier, and 12 GB-class
  memory (ADR 0012). Below it the app shows an explanation, not a degraded
  mode.
- **Challenge set** — synthetic mistake classes beyond the regression
  taxonomy (`SyntheticRGBD --suite challenge`), reported per class and never
  gated or used as release evidence. An **expected failure** is a class
  the current sensors cannot catch by construction (a colour swap under
  depth-only verification); it is counted as `xfail` until the capability
  lands.
- **Admission** — the runtime resource gate for the on-device VLM only
  (ADR 0003). It reads the process budget (available plus footprint), with
  hysteresis, and releases the model under critical memory pressure.
  Geometric features are never admission-gated.
- **Thermal policy** — `InferencePolicy`: at `serious` no VLM recovery
  starts (one check still may); at `critical` no VLM work starts at all.
  Geometric recovery always runs; an inconclusive fit with the VLM withheld
  is insufficient with cause `thermal_deferred`.
- **Build session** — `BuildSessionController`, the single owner of a
  model's build progress. Every confirm (guide, AR, photo check, recovery)
  goes through it with its source, so views never keep private copies of
  the current step.
- **Photo check** — one VLM call judging a photo against the current step's
  cumulative target: complete, incomplete, or uncertain, always advisory.
  From Check Step it compares against the guide camera; in the AR guide it
  runs only under a locked registration and pauses live verification while
  it holds the GPU.
- **Check target** — which render a photo check compares against:
  `guide_camera` (the fixed three-quarter view, the baseline) or
  `registered` (the photo's own camera under the locked pose). A recorded
  variant axis.
- **Inference variant** — `RecoveryInferenceVariant`: every axis that
  changes what the VLM sees or how its output is decoded (decoder, vote,
  slot uniqueness, scoring, slot order, board, labels, prompt, image side,
  check target). Recorded on every trace; its `id` names only the
  non-default axes, so the baseline is `baseline`.
- **Arm** — one side of an A/B: a variant plus a label (`arm_id`). Device
  arms come from the developer arm picker (single, or interleaved with the
  control); paired comparison happens on Mac replay (`compare_arms.py`).
- **Readout** — the model's masked probability distribution at a decision
  with a small legal set (a slot letter, a status), recorded beside the
  token it chose, so thresholds can be re-derived offline.
- **Unmeasured gate** — a release gate with no rows to judge it. In release
  mode a required unmeasured gate fails; it is never read as zero.
- **Build diff** — `BuildDiffEngine`'s judgement of the current step's
  delta, placement by placement, against depth (M2.3). It returns
  `BuildDiff`. Its legacy-equivalent verdict matches the verifier exactly.
  It runs as a shadow judge until it has authority (ADR 0008 amendment).
- **Placement state** — one placement's finding in a build diff
  (`PlacementState`): present, absent, displaced by whole studs, rotated
  (asymmetric parts only), colour mismatch (with the colour check on), or
  not observable. Plate-height offsets are observe-only.
- **Shadow judge** — a second judge fed the same frames after the
  authoritative one (`ShadowStepJudging`), only while evidence capture is
  on. Logged and written to evidence (`diffs.ndjson`), never shown.
- **Evidence window** — the verifier's last eight frames (about 1.6 s), with
  their registrations and verdicts. Saved on a verdict change, a confirm,
  an override and a step exit while evidence capture is on (ADR 0007
  amendment 2). `SyntheticRGBD --replay-bundle` replays windows on a Mac.
- **Repair plan** — `RepairPlanner`'s deterministic actions for the current
  step's parts: add, move by whole studs, turn, or swap for the authored
  colour (ADR 0015). Worded by `RepairPhrasebook` from the String Catalog,
  or, behind a developer setting, by a validated language-layer sentence
  (ADR 0017). Directions come from poses, never from a model. Cross-step plans (`CrossStepRepairPlanner`) are
  Proposed and stay behind an off flag.
- **Suggested placement** — a ghost pose fitted to the depth under the
  reticle (`SuggestedPlacementEstimator`). Offered only behind a developer
  flag, and registration starts from it only after the user taps "Use
  Suggested Position" (ADR 0009 amendment).
- **Advance policy** — `AdvancePolicy`: what "next" does by voice or Siri.
  It holds on a negative check, advances on complete, uncertain or no
  check, only browses off the frontier, and refuses when no guide is on
  screen (ADR 0016).
- **Tag pass** — the expected-depth renderer's second pipeline, writing each
  surface's LDraw colour code + 1 (0 is background) beside depth (M3.1,
  ADR 0006 note). Depth beside it is bit-identical to depth alone.
- **Colour term** — `ColourAgreementTerm`, the non-learned RGB half of
  ADR 0008. It compares the delta's depth-confirmed pixels, in calibrated
  Oklab, with the authored colour, the nearest other colour the model uses,
  and the colour beneath. The answer is agrees, disagrees (naming the other
  colour) or inconclusive (with a reason). Its say over the verdict is a
  `ColourTermMode`: off, shadow, block only (may take a complete away), or
  full (replay only: may also corroborate a marginal delta that depth
  calls present). Colour never completes anything on its own.
- **Scene colour calibration** — the per-channel gain the colour term fits
  from parts already built ("the completed parts are the colour chart").
  It needs at least two colours.
- **Language layer** — the on-device system model phrasing a repair the
  planner already decided (ADR 0017). It gets the facts in the Prompt and
  must repeat them; the template shows first and stays on any failure.
- **Wording validator** — `RepairWordingValidator`: a generated sentence
  may not add a direction, number, colour, rotation sense or forbidden word
  that the facts lack.
- **Step-check advisor** — what answers a photo check (`StepCheckAdvisor`).
  Today it is the VLM. The Foundation Models advisor runs beside it only
  as a shadow check (ADR 0018).
- **Shadow check** — that advisor's run after an AR photo check: a
  standalone verdict, a closed "is the part there?" on the geometry crop,
  and a merge that may only take a complete away. Recorded
  (`shadow-checks.ndjson`, `shadow_check` rows), never shown.
- **Lattice runner-up** — the competing pose that came closest to the
  registration's fit and so set its lattice margin: one stud along the
  model's x or z, or a half or quarter turn (`lattice_runner_up`, Phase 4).
- **Lattice contest** — one of the verifier's four ±1-stud contests: on
  pixels where the authored and the shifted placement predict different
  depth, which one the observation matched (`lattice_contests`). A
  misplaced verdict is decided on them.
- **Pitch-off** — a registration that settled within 2 mm of a whole stud
  pitch from the truth, at the true yaw: what lattice aliasing looks like
  in a result.
- **Stud index** — every stud primitive in a flattened timeline, with its
  placement, keypoint (a top stud's top face centre), axis, scale and the
  triangles it drew (`StudIndex`). Groups (`stug…`) resolve to their studs.
- **Stud label** — where a top stud's keypoint lands in a view and whether
  the view sees it. Synthetic labels are geometry only; labels on real
  photo captures are pseudo-labels through the locked pose, refused near a
  lattice alias (ADR 0020).
- **Adapter** — a LoRA adapter applied unfused over the pinned VLM
  weights: a model variant, `adapter=<name>@<sha12>` (ADR 0019).
- **Smoke adapter** — an adapter trained on a synthetic smoke bundle to
  prove the pipeline. Named `smoke-…`, refused by the release scorer, never
  committed.
- **Physical build** — the physical object a staged session photographs,
  labelled `physical_build_id`. Training splits keep each physical build,
  and each authored model, on one side.
- **Training pair** — one exported rank trace: the stored board, the
  verbatim prompt, and a target that names the truth slot first after the
  probe's prefix.

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
- `Bricky/App` owns the device floor (`DeviceFloor`), document opening, and
  `BuildSessionController`, the single owner of build progress.
- `Bricky/Services/Recovery` owns transient alignment, guided capture, bounded
  comparison boards, model delivery (a background `URLSession`, verified in
  the foreground), admission and the memory governor, the thermal policy,
  hierarchical and composite estimation, the shared VLM step check, the
  inference-arm scheduler, and opt-in evidence recording (ADR 0007).
- `Bricky/Services/Registration` (triad) owns the depth-ICP tracker, surface
  sampling, and the one process-wide expected-depth renderer, which batches
  a caller's passes into one command buffer (ADR 0006).
- `Bricky/Services/Verification` (triad) owns the geometric step verifier,
  the controller that runs it beside tracking (latest frame only, never
  inside the ICP loop), and the AR photo-check controller.
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
- **Fit Record** — the record of one candidate step scored by a geometric
  recovery attempt: its fit quality, the two-sided coverage terms that
  decided it, the solved pose, and why it was ruled out if it was. A fit is
  not an inference call, so it is never an Evidence Trace.
- **Evidence Session** — one recovery run's traces, fit records, image and
  depth copies, ground truth, and estimate summary under
  `Evidence/<session>/`. Sessions are copies; they never own recovery work
  files.
- **Evidence Bundle** — the versioned zip a user explicitly exports from the
  Developer section. Its directory layout is the interchange format consumed
  by `bricky-harness` and Python tooling.
- **Staged Fixture** — a corpus-collection session whose expected step and
  conditions (lighting, occlusion, physical case, legal use) were declared
  before capture. Produces a fully-populated `RecoveryBenchmarkV1` row. A
  staged photo check declares the true step the same way; a build declared
  short of the checked step is a check negative, the only source of them.
- **Provenance** — where a benchmark row came from: `device`, `synthetic`,
  or a `replay:` device model. Release corpora take device rows only, from
  an `iPhone<≥18>` identifier; synthetic, replay, challenge, and
  expected-failure rows never count toward a release gate.
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

# Did this change make the solver worse? (blocking in CI; needs no calibration)
# Row counts are guarded alongside the rates, so a rate cannot improve by
# losing cases. --update adds new count metrics and refuses to retire a
# guard that stopped being measured unless it is named with --drop.
python3 check_regression.py synthetic.ndjson \
  --baseline ../SyntheticScenes/fixtures/real-tower/baseline.json

# Release mode judges each gate on a one-sided 95% bound; this prints how
# many zero-miss rows each gate needs. --informational scores a small
# corpus on point estimates without failing unmeasured gates.
python3 score_results.py --explain-minimums

# Mac replay of a device evidence bundle, one arm per variant, then a paired
# comparison (exact McNemar with Holm; refuses fewer than 20 pairs):
swift run --package-path ../../Packages/RecoveryMLX bricky-harness replay \
  --bundle bundle --model-dir /path/to/Qwen3-VL --model-revision <rev> \
  --out control.ndjson --arm control --checks
swift run --package-path ../../Packages/RecoveryMLX bricky-harness replay \
  --bundle bundle --model-dir /path/to/Qwen3-VL --model-revision <rev> \
  --out variant.ndjson --arm B --decode feed_all --checks
python3 compare_arms.py --control control.ndjson --variant variant.ndjson

# The challenge suite: mistake classes the regression taxonomy lacks, scored
# per class and never gated. Its baseline records today's known false
# completes (a brick one plate too high; colour swaps, an expected failure).
SyntheticRGBD ../SyntheticScenes/fixtures/challenge/challenge.ldr \
  --ldraw-root /path/to/ldraw --out challenge.ndjson --seed 7 --suite challenge
python3 check_regression.py challenge.ndjson \
  --baseline ../SyntheticScenes/fixtures/challenge/baseline.json

# Repairs (in-step and cross-step), geometric recovery (control and tie-break
# arms) and suggested placement, each against its own baseline:
SyntheticRGBD ../SyntheticScenes/fixtures/challenge/challenge.ldr \
  --ldraw-root /path/to/ldraw --out repair.ndjson --seed 7 --suite repair
python3 check_regression.py repair.ndjson \
  --baseline ../SyntheticScenes/fixtures/challenge/repair-baseline.json
SyntheticRGBD ../SyntheticScenes/fixtures/challenge/challenge.ldr \
  --ldraw-root /path/to/ldraw --out placement.ndjson --seed 7 --suite placement
python3 check_regression.py placement.ndjson \
  --baseline ../SyntheticScenes/fixtures/challenge/placement-suggestion-baseline.json
for arm in control tiebreak; do
  SyntheticRGBD ../SyntheticScenes/fixtures/challenge/challenge.ldr \
    --ldraw-root /path/to/ldraw --out recovery-$arm.ndjson --seed 7 \
    --suite recovery --recovery-arm $arm
  python3 check_regression.py recovery-$arm.ndjson \
    --baseline ../SyntheticScenes/fixtures/challenge/recovery-$arm-baseline.json
done
python3 compare_arms.py --control recovery-control.ndjson \
  --variant recovery-tiebreak.ndjson --primary session_top1

# Replay a device evidence bundle's verification windows on a Mac, judged
# by the verifier or the build diff:
SyntheticRGBD model.ldr --ldraw-root /path/to/ldraw --replay-bundle bundle \
  --out replay.ndjson --judge diff

# Pixels that differ between colour-ordered and timeline-ordered draws:
SyntheticRGBD model.ldr --ldraw-root /path/to/ldraw --out order.ndjson \
  --check-render-order

# The colour tag pass beside depth (blocking in CI): depth unchanged, tags
# decode to the step's colours, coverage matches.
SyntheticRGBD model.ldr --ldraw-root /path/to/ldraw --out tags.ndjson \
  --check-tag-render

# Colour-term arms on real windows (synthetic scenes carry no colour, so
# this needs a device bundle), paired by window:
SyntheticRGBD model.ldr --ldraw-root /path/to/ldraw --replay-bundle bundle \
  --out shadow.ndjson --colour-term shadow
SyntheticRGBD model.ldr --ldraw-root /path/to/ldraw --replay-bundle bundle \
  --out full.ndjson --colour-term full
python3 compare_arms.py --control shadow.ndjson --variant full.ndjson \
  --primary verification_correct

# Repair wording: a blinded sheet from device wording.ndjson pairs, then
# the sign test once the rater has filled in `choice`:
swift run --package-path ../../Packages/RecoveryMLX bricky-harness wording-sheet \
  --bundle bundle --out-sheet sheet.csv --out-key key.csv
python3 score_wording_ab.py --sheet sheet.csv --key key.csv

# Photo checks through the Foundation Models advisor on a macOS 27 Mac
# (informational; ADR 0018 is decided by device rows):
swift run --package-path ../../Packages/RecoveryMLX bricky-harness fm-shadow \
  --bundle bundle --out fm.ndjson
python3 compare_arms.py --control vlm.ndjson --variant fm.ndjson --primary check_correct

# The language layer's live tests and Evaluations suite (macOS 27 only):
BRICKY_FM_LIVE=1 swift test --package-path ../../Packages/RecoveryMLX \
  --filter "RepairWordingLiveTests|StepCheckAdviceLiveTests|RepairWordingEvaluationTests"
```

## Release gates still requiring physical assets or devices

- 🔴 GAP — synthetic gates green in CI: registration convergence ≥95% with
  ≤3 mm / ≤2° error on the perturbation sweep, ambiguity recall ≥90%,
  verification false-complete rate ≤2% (reported first), per-class
  precision/recall ≥0.90/0.85 (strong detectability) and ≥0.80/0.70
  (marginal), undetectable-abstention ≥95%, uncertain-on-correct ≤15%.
  These are *certification* gates and stay informational in CI while the
  synthetic sensor constants remain RECONSTRUCTED (ADR 0014,
  [SENSOR_CALIBRATION.md](docs/SENSOR_CALIBRATION.md)). *Regression* against
  a committed fixture baseline blocks today and needs no calibration — the
  two questions were previously conflated in one job that could answer
  neither. The marginal precision/recall pair is dormant by decision until
  the RGB support term lands (ADR 0008 amendment).
- 🔴 GAP — physical corpus: one row per staged fixture across ≥6 legally
  usable authored models (a floor pending an owner decision between 6 and
  10) with lighting/angle/occlusion variation; registration error ≤5 mm
  against a jig; the synthetic verification gates re-met on device; median
  latencies ≤3 s verification, ≤8 s geometric recovery, ≤20 s composite
  recovery. Release mode judges every gate on a one-sided 95% confidence
  bound and fails any required gate it could not measure, so the corpus size
  follows from the gates (`score_results.py --explain-minimums`: e.g. ≥149
  negatives for false-complete ≤2%) rather than from a fixed row count.
- 🔴 GAP — profile the production-sized warm-up while AR, scene mesh, and the
  ICP tracker are active on an iPhone 17 Pro, set the memory floor to the
  measured peak (lifetime `phys_footprint` peak less the pre-load
  footprint, which every admission records) plus 25%, and confirm the
  device floor's memory threshold (ADR 0003 and ADR 0012 amendments).
- 🔴 GAP — step-check false-complete has a device producer
  (`check.ndjson`, staged labels only) but no rows yet: Phase 1 must
  collect staged check sessions, including negatives.
- 🔴 GAP — the colour term's authority (ADR 0008 amendment, Proposed) needs
  ≥40 real staged verification fixtures with colour swaps and marginal
  steps; its thresholds are RECONSTRUCTED until then.
- 🔴 GAP — ADR 0018 needs ≥149 staged device negatives with the shadow
  check on; repair wording's default needs a blinded preference win on
  device pairs (ADR 0017). Both are re-run per OS build.
