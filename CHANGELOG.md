# Changelog

## Unreleased — the LoRA transfer gap, explained (tooling only)

- **Cause found.** Swift ran Python-trained adapters at 0.73 of their
  strength, and its base log-odds were 0.79 times Python's. The device
  runtime computes the vision MLP with the sigmoid GELU, while the model
  (and mlx-vlm) use tanh GELU.
- **Fix.** `Tools/Training` now trains and scores with the device's
  activation (`--vision-gelu device`, the default; `common.match_device`).
  The app is unchanged.
- **Result on the smoke run.** Transfer slope 1.015, base slope 0.997 and
  mean difference 0.09 nats, so ADR 0019 criterion 4 is met. Whether the
  device should switch activations is left as an A/B (NEXT_STEPS §2).

## Unreleased — review follow-ups for #12–#14

Fixes for review findings that were left open when those PRs merged. None
changes a verdict the user sees.

- **Fix.** The exporter refuses a bundle whose `sessions` folder is a
  symlink pointing outside it. Without that, `--copy-images` could copy
  foreign boards into training data. This fix missed the #14 merge.
- **Fix.** Spotlight syncs run one at a time, each reading the setting
  when it runs. A sync that was enabled could otherwise finish after a
  later opt-out and index every model again.
- **Fix.** The build diff no longer votes with a frame whose render
  outlived a step change or an evidence reset.
- **Fix.** An evidence window pairs the verifier's, the shadow's and the
  colour term's readings of the same frame:
  - Verdict-change windows used to pair frame N's verdict with frame
    N−1's shadow diff. Those are the `diffs.ndjson` rows the ADR 0008 flip
    gate reads.
  - A reading from another frame is now left out, and a failed shadow
    judgement clears the last one.
  - No real rows had been recorded yet.
- **Fix.** Evidence-window frames are validated like depth frames: depth
  version, intrinsics and pose lengths, and size overflow. A malformed
  frame used to replay under the wrong geometry without any error.
- **Fix.** Purging the placement geometry also drops a build in flight,
  so geometry built after the AR guide closed no longer stays in memory.
- **Fix.** A whole turn or a zero offset in the build diff plans no
  repair. The Foundation Models wording test now follows the toolchain.

## Unreleased — iOS 27 Phase 4: lattice evidence, stud labels, LoRA tooling (nothing trained ships)

Nothing here changes what a user sees, and no model or adapter is trained
for use: every Phase 4 entry criterion waits on Phase 1 device data.

- **Lattice aliasing, measured.** Evidence now records:
  - which lattice alternative set the registration margin, on window
    frames, fits and photo captures;
  - the verifier's ±1-stud contests;
  - the build diff's tallies.

  A synthetic lattice suite gives ambiguity recall real cases, with truth
  from renders. `bricky-harness lattice-rows` and the scorer's
  `STUD_KEYPOINTS_ENTRY` line decide when stud keypoints may start
  (ADR 0020, Proposed).
- **Stud labels.**
  - Stud primitives keep their identity through the flatten.
  - The tag pass renders stud ids, with depth bit-identical and a CI gate
    that also checks the stud catalog against the pinned pack.
  - SyntheticRGBD writes geometry-only labels, and pseudo-labels for real
    photo captures, refusing poses near a lattice alias.
  - A Core AI detector seam is type-checked against the device SDK in CI.
- **LoRA tooling** (ADR 0019, Proposed).
  - Staged sessions can label their physical build.
  - Variants gain an `adapter` axis.
  - The runtime loads converted adapters unfused, refusing implicit scales,
    missing layers and the wrong dtype. A zero-B adapter replays the
    baseline bit for bit.
  - A stdlib exporter splits pairs by authored model and physical build.
  - `Tools/Training` trains with mlx-vlm, converts, scores and checks
    Python/Swift parity. Replays warm up first, as the app does at
    admission: the first inference after a load is not bit-reproducible.
  - **Open finding:** Swift applies the converted adapter as Python does
    (r 0.95; a ×2 canary stands out), but shows only 0.73 of its effect,
    and the base models already differ (slope 0.79). ADR 0019 now requires
    this transfer gap closed before any real training.
  - `compare_arms.py` refuses arms on different weights, and adapter arms
    scored on their own training data.
- **Fix.** `ProbeScoring.group` summed probabilities in dictionary order,
  so two identical probe calls could differ in the last bit.
- **Fix.** Background model delivery published first and checked for
  running transfers second. A download finishing in between was started
  again: a second multi-GB transfer. It now checks first. The test that
  hung CI for 40 minutes on this race now places the finish
  deterministically instead of sleeping.

## Unreleased — iOS 27 Phase 3: colour, wording and a second opinion (all off by default)

Nothing here changes what a user sees unless a developer setting turns it
on, and nothing has authority before Phase 1 device data exists.

- **Colour check** (ADR 0008 amendment, Proposed). The expected-depth
  renderer gains a colour tag pass, with depth unchanged and a CI gate for
  it. A non-learned colour term compares the step's depth-confirmed pixels,
  calibrated against the parts already built, with the authored colour. In
  the AR guide it can run in shadow, or block a complete when the colour is
  another one the model uses. The shadow build diff names wrong-colour
  placements. Real windows replay through each mode on a Mac.
- **Repair wording** (ADR 0017). Repairs can be reworded by the on-device
  language model. The sentence must repeat the plan's facts and add
  nothing, and the template shows first and stays on any failure. Device
  pairs feed a blinded preference test.
- **Second opinion on photo checks** (ADR 0018, Proposed). The Foundation
  Models advisor judges each AR photo check after the VLM, recorded only,
  with a merge that may only take a complete away. Device rows decide
  whether the VLM ever leaves the step check.
- **Evidence.** Photo checks record the model pose and where the step's
  parts fell in the photo. New files: `wording.ndjson`,
  `shadow-checks.ndjson` and `shadow_check.ndjson`.
- **One source for the check verdict.** The MLX grammar's bytes are pinned,
  and the cloud schema, app enum and scorer mirror it.
- **Private Cloud Compute** was considered and is not available to this
  developer account (ADR 0011 note).

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
