# Evidence formats: sessions, traces, bundles, benchmark rows

Status: all format versions are 1. Last revised 2026-08-04.

The on-device session directory layout **is** the export interchange format
(ADR 0007). Everything is dumb files — JPEG plus JSON/NDJSON with snake_case
keys — so `bricky-harness` and Python tooling read them without Swift. The
single Swift definition of every type in this document is
`Packages/RecoveryMLX/Sources/RecoveryEvidenceKit/EvidenceSchemas.swift`.

## Versioning and encoding rules

Three independent version stamps, each carried inside its own file:

| Stamp | Field | Current |
| --- | --- | --- |
| Trace row | `trace_version` | 1 |
| Session file | `session_version` | 1 |
| Bundle manifest | `bundle_version` | 1 |

Rules:

- Encode with `EvidenceSchema.encoder()`: ISO-8601 dates, sorted keys
  (deterministic diffs), pretty-printed only for `session.json` and the
  manifest.
- **Every type spells out snake_case `CodingKeys` explicitly.** Foundation's
  `convertFromSnakeCase` strategy is banned in interchange types: it cannot
  round-trip properties like `traceID` (`trace_id` decodes to `traceId`,
  not `traceID`) or `schemaJSON`, so it fails silently exactly where these
  schemas need acronym-heavy names.
- Adding a field = add it as *optional* without a version bump (readers
  tolerate absence). Renaming, retyping, or changing semantics of an
  existing field = bump the relevant version; `EvidenceBundleReader.validate`
  and the package tests reject unknown versions loudly rather than
  misreading them.
- `RecoveryBenchmarkV1` is versioned separately (`schema_version: 1`) because
  its contract is owned by `Tools/RecoveryEvaluation/score_results.py`, not
  by the evidence store.

## Directory layout

On device (Application Support namespace), per session:

```text
Evidence/<session-uuid>/
  session.json          # one EvidenceSessionFile (pretty-printed)
  traces.ndjson         # one EvidenceTraceRow per inference call
  fits.ndjson           # one GeometricFitRecord per scored candidate (optional)
  benchmark.ndjson      # 0 or 1 RecoveryBenchmarkV1 rows (labeled sessions)
  check.ndjson          # one VLMCheckRowV1 per check call (labeled sessions with checks)
  verification.ndjson   # one VerificationRowV1 per closed staged verification (AR guide)
  diffs.ndjson          # one BuildDiffRecord per window, when the shadow build diff ran
  windows/<window-uuid>.json           # VerificationWindowRecord
  windows/frames/<frame-uuid>.json     # EvidenceDepthFrameRecord for one judged frame
  windows/frames/<frame-uuid>.{depth,confidence,raw-depth,raw-confidence}
  windows/frames/<frame-uuid>.colour   # uint8 RGB, interleaved, on the depth grid (optional)
  windows/frames/<frame-uuid>.occluder # uint8 0/1 person mask on the depth grid (optional)
  captures/<capture-uuid>.jpg          # the 3 guided AR photos (copies)
  boards/<trace-uuid>.jpg              # exact board image the model saw
  tiles/<trace-uuid>/<slot>.jpg        # per-candidate renders, JPEG q0.9
  depth/<capture-uuid>.json            # EvidenceDepthFrameRecord sidecar
  depth/<capture-uuid>.depth           # float32 smoothed depth, row-major
  depth/<capture-uuid>.confidence      # uint8 ARConfidenceLevel
  depth/<capture-uuid>.raw-depth       # float32 unsmoothed (optional)
  depth/<capture-uuid>.raw-confidence  # uint8 (optional)
```

`fits.ndjson` is absent when the recovery never ran a geometric pass, and
`traces.ndjson` is absent when the geometric pass concluded without loading
the VLM. A session normally has one or the other; a composite recovery has
both.

An exported bundle wraps selected sessions verbatim:

```text
bricky-evidence-<yyyyMMdd-HHmmss>.zip
└─ (unzipped root)
   ├─ evidence_bundle.json             # EvidenceBundleManifest
   └─ sessions/<session-uuid>/...      # session dirs, byte-identical
```

## `evidence_bundle.json` — EvidenceBundleManifest

| Field | Type | Notes |
| --- | --- | --- |
| `bundle_version` | int | 1 |
| `created_at` | ISO-8601 | export time |
| `app_version` | string | CFBundleShortVersionString |
| `device_model` | string | utsname hardware id, e.g. `iPhone17,1` |
| `operating_system` | string | full version string |
| `model_id` | string | Hugging Face model id |
| `model_revision` | string | pinned revision SHA (ADR 0013) |
| `session_ids` | [uuid] | what the user selected for export |

**Synthetic smoke bundles.** `bricky-harness synth-bundle` writes bundles for
the training pipeline's end-to-end test (ADR 0019). Their `device_model` is
`synthetic:bricky-harness` in the manifest and every session, and their
traces record `raw_output` `""` and `termination` `not_run`: no phone and no
model ever saw them. Every release path and the training exporter refuse
them; they are fixtures, never evidence.

## `session.json` — EvidenceSessionFile

Identity and environment: `session_version`, `session_id`, `created_at`,
`instruction_sha256`, `authored_model_id` (uuid), `model_title`,
`step_count`, `model_revision`, `device_model`, `operating_system`,
`app_version`.

Mutable over the session's life:

- `captures` — array of capture records:
  `capture_id`, `image_relative_path`, `camera_transform` (16 floats,
  column-major 4×4), `camera_intrinsics` (9 floats, column-major 3×3),
  `camera_image_resolution` ([w, h]), `alignment_id`, `angle`,
  `captured_at`, and optional `world_from_model` (16 floats, column-major
  4×4, the same layout as `camera_transform`): the locked registration's
  model pose, recorded only for AR photo checks (ADR 0007 amendment 3).
  Verification-window poses are row-major; this one is not. AR photo checks
  also stamp the live registration the photo was taken under:
  optional `registration_state`, `lattice_margin` and `lattice_runner_up`
  (names below). A label derived from `world_from_model` can then be
  refused when the pose sat near a lattice alias.
- `staged` — nullable `StagedFixtureDeclaration`:
  `expected_completed_count` (0 = not started), `lighting`
  (`bright`/`dim`/`mixed`), `occlusion` (`none`/`partial`/`heavy`),
  `physical_case` (bool), `legal_use_confirmed` (bool, required to save).
- `ground_truth`:
  - `kind` — `staged` (declared before capture; the declaration is the
    label), `confirmed` (labeled by the user's Confirm after a real
    recovery), or `unlabeled` (failures and abandoned sessions, kept
    deliberately).
  - `expected_completed_count`, `expected_step_id` — the label.
  - `confirmed_completed_count`, `confirmed_at` — on staged sessions this is
    a *cross-check* against the declaration, never the label.
- `estimate` — nullable summary: `ranked_step_ids`, `certainty`,
  `insufficiency_cause` (nullable: `broad_pass_unmatched`,
  `narrowing_pass_unmatched`, `final_pass_unmatched`,
  `finalist_quorum_not_reached`, `geometric_inconclusive_without_fallback`,
  `thermal_deferred`), `latency_ms`, `method`
  (`geometric` / `composite` / `vlm`), and `model_revision`. The last two are
  the estimate's own, not the session header's — see `benchmark.ndjson`.
- `analysis_error` — nullable string when the run threw.
- `physical_build_id` — optional (added 2026-10-07, ADR 0019): the
  physical build the session photographed, as a slug matching
  `[a-z0-9-]{1,32}` that the person declares on the staged-fixture sheet
  (or `b-` plus four hex digits from "New Build"). It is remembered per
  instruction model, so a re-shot build keeps its label. Staged sessions of
  a physical build carry it; a confirmed recovery takes the last label
  declared for its model. Training data is split by it as well as by
  authored model, so sessions sharing either stay on one side.

## `fits.ndjson` — GeometricFitRecord (one line per scored candidate)

Geometric recovery is the primary path (ADR 0010) but produced no evidence,
so a bundle could only ever explain the VLM fallback. These rows answer the
geometric analogue of what the trace rows answer: which candidates were
considered, what each scored, and — when the truth lost — which term beat it.

| Field | Type | Notes |
| --- | --- | --- |
| `fit_version` | int | 1 |
| `fit_id` | uuid | |
| `session_id` | uuid | |
| `pass_index` | int | which coarse-to-fine refinement pass scored it |
| `candidate_index` | int | position in `plan.steps`; **-1 is step zero** |
| `step_id` | string | e.g. `main.ldr#4` |
| `score` | float | two-sided coverage; comparable only within one attempt |
| `inlier_fraction` | float | from the ICP solve |
| `visible_fraction` | float | how much of the sample was on camera |
| `unexplained_fraction` | float | observed structure the candidate cannot explain |
| `phantom_fraction` | float | candidate surface with nothing observed at it |
| `rms_residual` | float | meters |
| `lattice_margin` | float | 1.0 means an alternative explains depth equally well |
| `world_from_model` | [float] | 16 values, **row-major** |
| `disqualification` | string | `none`, `vertical_deviation`, `horizontal_deviation` |
| `conclusive` | bool | true on the candidate the attempt concluded with |
| `created_at` | ISO-8601 | |
| `lattice_runner_up` | string? | the alternative that set `lattice_margin`; absent when no sweep ran |

**Lattice runner-up.** The tracker scores six competing poses against the
fit (ADR 0009) and keeps the smallest cost ratio as `lattice_margin`.
`lattice_runner_up` names the one that set it, in the model frame:
`shift_x_pos`, `shift_x_neg`, `shift_z_pos`, `shift_z_neg` (one stud along
the model's x or z), `yaw_180`, or `yaw_90` (near-square footprints only).
It is absent when no sweep ran (the fit was below the loss floor) or when
every alternative left the image. It is evidence only: the lock rule reads
the margin alone.

`unexplained_fraction` and `phantom_fraction` weigh into `score` identically,
so without both a losing candidate cannot be told from one that lost the
other way. `disqualification` is recorded separately because a disqualified
candidate's `score` is a clamped sentinel, not a measurement — the clamp is
what keeps it from winning, and it cannot also carry the reason.

## `traces.ndjson` — EvidenceTraceRow (one line per inference call)

| Field | Type | Notes |
| --- | --- | --- |
| `trace_version` | int | 1 |
| `trace_id`, `session_id` | uuid | |
| `pass` | string | `broad`, `narrowing`, `narrow`, `finalist`, `check` |
| `pass_index` | int | narrowing iteration, or finalist view index (sorted by angle) |
| `capture_id`, `capture_angle` | uuid?, string? | which guided photo fed the board |
| `board_relative_path` | string | `boards/<trace-uuid>.jpg` — exactly what the model saw |
| `tile_relative_paths` | {slot → path} | individual candidate renders |
| `candidate_step_indices` | {slot → int} | **-1 means step zero** (see below) |
| `candidate_step_ids` | {slot → string} | authored step identifiers |
| `prompt` | string | verbatim |
| `schema_json` | string | the exact grammar schema for this call (slot-count dependent) |
| `max_tokens` | int | budget in force |
| `raw_output` | string | full model text, including truncated prefixes |
| `decode_error` | string? | nil when `raw_output` decoded against the schema |
| `termination` | string | `accepted`, `max_tokens_exhausted`, `premature_eos`; `not_run` only in synthetic smoke bundles |
| `generated_tokens` | int? | nil on abnormal termination (loop throws before counting) |
| `latency_ms` | int | wall clock around the guided loop |
| `memory_footprint_bytes` | int64? | `phys_footprint` at record time |
| `model_revision` | string | |
| `created_at` | ISO-8601 | |

## Verification windows — `windows/`

Recorded by the AR guide while evidence capture is on (ADR 0007 amendment 2).
A `VerificationWindowRecord` holds:
- `window_id`, `session_id`, `step_id` and `step_index` (the plan index);
- `trigger`: `verdict_change`, `confirm`, `override` or `step_exit`;
- `created_at`;
- the published verdict when the window closed: `verdict`, `offset_studs`,
  `uncertain_reason`, `detectability`, `delta_pixels`, `frames_used` and
  both fractions. `frames_used` counts every frame since the step began,
  not only the window's;
- `staged`: the declared truth, or null;
- `colour_term` (optional, added 2026-10-06; ADR 0007 amendment 3): when
  the developer colour check is on, its `mode` (`shadow` or `block_only`),
  overall `status` (`agrees`, `disagrees`, `inconclusive_<reason>`),
  `frames_with_colour`, `frames_calibrated`, and `groups`, one per authored
  colour: `code`, `status`, `pixels`, `frames`, and the Oklab distances
  `authored_distance` and `nearest_distance`, plus `nearest_code` and
  `beneath_code`. The verdict above already reflects the mode;
- `lattice_contests` (optional, added 2026-10-07): the verifier's four
  ±1-stud contests, one entry per alternative: `offset_studs` (`[dx, dz]`),
  `wins_complete` and `wins_shifted`, the exclusive-evidence pixels that
  matched the authored and the shifted placement, counted since the step
  began like `frames_used`. A `misplaced` verdict is decided on these; stud
  keypoints (ADR 0020) must show they are where the verifier goes wrong;
- `frames`, oldest first.

Each entry in `frames` has `frame_id`, `registration_state`,
`world_from_model` (row-major 4x4), `rms_residual`, `inlier_fraction`,
`lattice_margin`, `verdict_after` and `ingest_ms`, plus the optional
`lattice_runner_up` (see `fits.ndjson`).

Each frame's planes sit under `windows/frames/`, named by an
`EvidenceDepthFrameRecord` sidecar whose `capture_id` is the frame id.
Frames shared by overlapping windows are written once. The sidecar's
optional `colour_relative_path` (RGB8, `width * height * 3` bytes) and
`occluder_mask_relative_path` (one byte per pixel) are new. So is
`colour_encoding` (e.g. `rgb8_bt709_full`): the colour is averaged in
Y′CbCr per depth cell, then converted with the buffer's matrix and range.

A `StagedVerificationDeclaration` has these fields:
- `scenario`: `complete`, `missing`, `shifted_one_stud`, `rotated`,
  `wrong_colour`, `plate_offset` or `hand_occluding`;
- `shift_direction_user`;
- `lighting`, `occlusion`, `physical_case` and `legal_use_confirmed`.

Each scenario implies an expected verdict:

| Scenario | Expected verdict | Notes |
|---|---|---|
| `complete`, `hand_occluding` | complete | |
| `shifted_one_stud` | misplaced | |
| `missing` | incomplete | |
| `rotated`, `wrong_colour`, `plate_offset` | incomplete | Challenge classes. `rotated` and `wrong_colour` are also expected failures. |

## `diffs.ndjson` — BuildDiffRecord

While evidence capture is on, the AR guide also runs the build diff (M2.3)
in shadow on the frames the verifier judged. Each window it closes adds one
row with these fields:
- `window_id`, `step_id` and `frames_used`;
- `placements`, one entry per placement the step adds:
  - `placement`, the timeline index;
  - `state`: `present`, `absent`, `displaced`, `rotated`,
    `colour_mismatch` (with the colour check on) or `not_observable`;
  - `offset`: `[dx, dz, dy, quarter_turns]`, for `displaced` and `rotated`;
  - the `support`, `absence` and `unexplained` votes, and `frames_seen`;
  - with the colour check on: `colour_status`, `colour_nearest_code` and
    `colour_authored_distance`;
  - `tallies` (optional, added 2026-10-07): each alternative's contest
    against the placement as authored, as `offset` (the layout above),
    `wins_present` and `wins_alternative`. Absent when no alternative was
    discriminable;
- `adapter_verdict`: the placement-aware verdict, which is logged only;
- `verifier_verdict`: what the user was shown.

`SyntheticRGBD --replay-bundle <bundle> --judge diff` replays windows
through the build diff instead of the verifier.

## `verification.ndjson` — VerificationRowV1

When a staged declaration closes (a confirm, an override, or leaving the
step), the closing window writes one `verification` row.

Its fields are:
- `fixture_id`: the window id;
- `expected_verdict` and `produced_verdict`;
- `detectability`;
- `latency_ms`: the verifier's compute time since the step began, with
  `latency_scope: verifier_compute_since_step_begin`;
- `device_model`, `authored_model_id` and `step_index`;
- `delta_pixels`, `frames_used` and `window_trigger`;
- the declaration's conditions;
- `challenge_class` and `expected_failure`, only for scenarios outside the
  release taxonomy.

SyntheticRGBD `--replay-bundle` writes the same row with `provenance: replay`,
`device_verdict` and `matches_device`. With `--colour-term
shadow|block|full` (M3.2, ADR 0008 amendment, Proposed) it judges each
window with that colour mode and adds `colour_term_mode`, `colour_status`
and, on a disagreement, `colour_nearest_code`. The scorer reports these as
an informational `colour_term` block, and `compare_arms.py --primary
verification_correct` pairs two modes' rows by window.

## `wording.ndjson` — RepairWordingRecordV1

Written by the AR guide with evidence capture on and the developer setting
"Reword repairs with the on-device language model" on (ADR 0017): one row
per finished wording attempt. Fields:
- `record_id`, `session_id`, `step_id`, `created_at`;
- the facts: `action`, `part_label`, `part_count`, `direction`, `studs`,
  `turn`;
- `template`: the String Catalog sentence;
- `model_sentence`: what the model wrote, accepted or not (null when it
  wrote nothing);
- `outcome`: `accepted`, `rejected_<reason>`, `unavailable_<reason>` or
  `failed_<reason>`;
- `shown`: the line on screen;
- `latency_ms`, `os_build`, `device_model`.

The model is not pinned, so `os_build` identifies it. These device pairs
are what the blinded preference test runs on.

## `shadow-checks.ndjson` and `shadow_check.ndjson` — the step-check advisor

With evidence capture on and the developer setting "Second opinion on photo
checks, recorded only" on, the AR guide's Photo Check runs the Foundation
Models advisor beside the VLM, in shadow (ADR 0018). It starts after the VLM
returns, and the user only ever sees the VLM's verdict.

- `shadow-checks.ndjson` (`ShadowCheckTraceV1`), one line per run, with:
  - `shadow_id`, `session_id`, `capture_id`, `step_index`, `advisor`
    (`foundation_models`) and `check_target`;
  - `primary_verdict`: what the user saw;
  - `standalone_verdict` and `standalone_outcome`: the advisor's own
    complete / incomplete / uncertain, or why it gave none;
  - `closed_answer` and `closed_outcome`: present / absent / cannot_tell on
    the photo and the registered render, both cropped to `check_geometry`'s
    box; skipped without a box or at the guide camera;
  - `merged_verdict`: the primary verdict after the merge, which may only
    turn a complete into an incomplete;
  - `had_delta_box`, `latency_ms`, `os_build`, `device_model`, `created_at`.
  It is a file of its own, not a new `pass` in `traces.ndjson`, whose
  reader is strict.
- `shadow_check.ndjson` (`ShadowCheckRowV1`, kind `shadow_check`): written at
  finalize for labeled sessions, one row per run. It has the expected
  verdict (the check's rule), the three verdicts, the closed answer, and the
  release fields of `vlm_check`. Release mode accepts only staged device
  rows from a floor device. The scorer prints the standalone false-complete
  rate first, with how many more negatives ADR 0018 needs (149 at zero
  misses).

## `check.ndjson` — VLMCheckRowV1

Written when a **labeled** session that ran photo checks is finalized, with
one row per check call (`kind: "vlm_check"`, `provenance: "device"`). The
fields are `fixture_id` (the check's trace uuid), `session_id`,
`expected_verdict` (complete when the labeled completed count reaches the
checked step, otherwise incomplete), `produced_verdict` (`uncertain` with
`decode_failed: true` when the answer did not decode), `latency_ms`,
`variant_id`, `check_target`, `model_revision`, `device_model`, `os_build`,
`label_kind` (`staged` or `confirmed`), `authored_model_id`, `step_index`
(plan index of the checked step), and the staged declaration's
`physical_case`, `legal_use_confirmed`, `lighting_condition` and
`occlusion_condition`.

`bricky-harness replay --checks` writes the same kind from Mac replays with
`provenance: "replay"`. Release mode accepts only device rows with
`label_kind: "staged"` from a floor device. A confirmed label exists only
when the user accepted the check, so it leans toward complete and stays
informational.

## `benchmark.ndjson` — RecoveryBenchmarkV1

Written once per **labeled** session by `RecoveryBenchmarkWriter` (device) or
derived by `bricky-harness replay` (Mac; always tagged
`device_model: "replay:<mac>"`, which `score_results.py` release mode
rejects — only `iPhone<≥18>,<n>` identifiers are device evidence). The
consumer contract is
`Tools/RecoveryEvaluation/score_results.py`; `BrickyTests/
RecoveryBenchmarkWriterTests.swift` mirrors its `REQUIRED_FIELDS` and
`RELEASE_FIELDS` sets so drift fails a test, not a release run.

Always present: `schema_version`, `fixture_id` (session uuid),
`instruction_sha256`, `pyldraw3_version`, `part_pack_version`,
`expected_step_id`, `candidate_slots` (slot → step id, from the center
finalist row), `board_relative_paths` (voting rows), `camera_metadata`
(per capture: `fx`, `fy`, `cx`, `cy` from the column-major intrinsics —
indices 0, 4, 6, 7 — plus `width`/`height`), `expected_step_index`,
`ranked_step_ids`, `certainty`, `estimator_method`, `device_model`,
`operating_system`, `latency_ms`, `memory_peak_bytes` (max footprint across
trace rows).

`estimator_method` is `geometric`, `composite`, or `vlm` (ADR 0010) and is
taken from the **estimate**, never from the session header — the header's
`model_revision` only records which VLM was loadable when the session
opened, which is true even of a recovery the geometric path answered
without loading any weights. The scorer buckets latency on this field;
`geometric` gates at 8 s and both fallback methods at 20 s. A `composite`
row's `latency_ms` covers both legs, because `CompositeRecoveryEstimator`
owns the wall clock while each underlying estimator times only itself.

Nullable / release-corpus fields: `model_revision` (informational — which
weights or solver produced the ranking; never parsed to infer the method),
`top_step_index` (null only when
`certainty` is `insufficient`), `physical_case`, `authored_model_id`,
`legal_use_confirmed`, `lighting_condition`, `capture_angle`,
`occlusion_condition`, `capture_elevation_degrees` (the center capture's
measured viewing elevation below the horizon, from its camera transform).
Release rows must populate all of them. Corpus-level requirements
(provenance, variation coverage including two elevation bands, and the
bound-based sample sizes) are in the scorer README.

## Benchmark-protocol telemetry (optional, added 2026-09-25)

All of these fields are optional additions (no version bump). They exist so
that device rows can be bucketed and controlled the way the benchmark
protocol requires: Release builds, cold/warm/sustained buckets, and
interleaved arms. The types live in `RecoveryEvidenceKit/RecoveryTelemetry.swift`.

| Where | Field | Meaning |
| --- | --- | --- |
| manifest, session | `os_build`, `gpu_architecture` | `kern.osversion`; Metal's architecture name |
| session | `physical_memory_bytes` | `ProcessInfo.physicalMemory` (the device-floor input) |
| session | `admission` | floor, available bytes at check, footprint before load, load and warm-up ms, warm-up lifetime peak |
| session | `conditions_start`, `conditions_end` | `DeviceConditions`: thermal state, Low Power Mode, battery level/state, `seconds_since_ar_start` (continuous AR), `ar_active_seconds` |
| trace | `variant` | `RecoveryInferenceVariant`: `decode`, `vote`, `unique_slots`, `scoring`, `slot_order`, `board_layout`, `labels`, `prompt_style`, `image_side`, `check_target`, `arm_id`, and `adapter` (`<name>@<sha12>`, a LoRA adapter over the pinned weights, ADR 0019; Mac replays only). Absent axes decode to the baseline |
| trace (checks) | `alternate_tile_relative_paths` | the target rendered from the check target the call did not use (`guide_camera` or `registered` → tile path). Written only with evidence on, and only when that target could be rendered: `registered` needs the AR guide's locked pose |
| trace (AR checks) | `check_geometry` | where the step's delta fell in the photo (added 2026-10-06, ADR 0007 amendment 3): `coordinate_space` (`upright_capture_normalized`: origin top-left of the upright stored photo, x right, y down, 0–1), `delta_box` (`x`, `y`, `width`, `height`; null when no delta pixel is visible), `delta_pixels`, `grid_width`, `grid_height` (the landscape render grid). Rendered on device from the photo's camera under the locked pose, after inference, with evidence on. The Mac cannot recompute it: bundles carry no instruction model |
| trace | `inference` | `decode` (prompt/image tokens; preprocess/prefill/decode ms; sampled/forced/fed/dropped tokens; `cache_offset`; fast-forward disagreements), `memory_before`/`memory_after` (`task_vm_info` footprint, lifetime peak, limit remaining, graphics), `thermal_before`/`thermal_after`, `calls_since_load`, `seconds_since_load`, `load_ms` |
| trace | `conditions` | `DeviceConditions` at the call |
| trace | `readouts` | per small-legal-set decision: position, chosen token, legal candidates with masked-softmax probabilities |
| benchmark | `variant_id` | the arm; the scorer refuses files that mix arms unless `--allow-mixed-arms` is passed |
| benchmark | `latency_bucket` | `cold` (first call after load), `warm`, or `sustained` (≥ 1800 s of continuous AR); the scorer reports p50/p95 per bucket |
| benchmark | `thermal_state_start`/`_end`, `seconds_since_ar_start`, `battery_state`, `low_power_mode` | conditions at the session's start and end |
| benchmark | `vlm_calls`, `prefill_ms_total`, `decode_ms_total` | what the estimate cost in inference |
| benchmark | `latency_scope` | `estimate_wall_clock` on device |

`memory_peak_bytes` is now the kernel's lifetime `phys_footprint` peak
(`ledger_phys_footprint_peak`), where the device has it. Before, it was the
largest of the footprints sampled after each call, which misses peaks that
happen inside a call. On macOS, `device_model` now reports `hw.model`
(for example `Mac14,12`); `uname` only gives `arm64`.

## Step numbering: the three coordinate systems

This is the highest-risk area of the format; one shared helper exists per
producer and both are covered by fixture tests.

1. **Internal step index** (`candidate_step_indices`): the position in
   `plan.steps`, with **-1 meaning step zero** (nothing built yet). Tile
   labels render `Step N` where N = index + 1.
2. **Authored step number / completed count** (`expected_step_index`,
   `top_step_index`, `expected_completed_count`): how many authored steps
   are complete, with **0 meaning step zero**. This matches the scorer's
   example fixtures. So authored number N ↔ internal index N − 1.
3. **Step identifiers** (`candidate_step_ids`, `ranked_step_ids`,
   `expected_step_id`): `"<rootSection>#<number>"` using the *authored*
   number, e.g. `main.ldr#4`; step zero is `plan.stepZeroID` =
   `"<rootSection>#0"`.

Mapping helpers: `RecoveryBenchmarkInputs.init(plan:expectedCompletedCount:)`
in the app (builds the id → authored-number map including step zero) and
`BrickyHarness.stepNumber(from:)` in the CLI (parses the `#N` suffix).

## Retention and safety guarantees

- The store is capped at **40 sessions / 2 GB**; `purgeIfNeeded` runs before
  each new session directory is created, deleting oldest-first and keeping
  64 MB of headroom for the incoming session.
- Sessions hold **copies only**. The recovery pipeline's four deletion sites
  and the startup orphan sweep (`RecoveryWorkFileCleanup`) are unchanged and
  never enter `Evidence/`.
- Recording is best-effort: recorder errors are logged (OSLog category
  `Evidence`) and swallowed so evidence can never break a recovery.
- Export staging uses hard links (copy fallback) and is deleted after
  zipping; the zip via the share sheet is the only egress (ADR 0007).
- `EvidenceBundleReader.validate` checks structure and file *existence*, not
  image decodability — a bundle with corrupt JPEGs passes `--dry-run` and
  fails at replay time.
