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

```
Evidence/<session-uuid>/
  session.json          # one EvidenceSessionFile (pretty-printed)
  traces.ndjson         # one EvidenceTraceRow per inference call
  fits.ndjson           # one GeometricFitRecord per scored candidate (optional)
  benchmark.ndjson      # 0 or 1 RecoveryBenchmarkV1 rows (labeled sessions)
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

```
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
  `captured_at`.
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
  `finalist_quorum_not_reached`), `latency_ms`, `method`
  (`geometric` / `composite` / `vlm`), and `model_revision`. The last two are
  the estimate's own, not the session header's — see `benchmark.ndjson`.
- `analysis_error` — nullable string when the run threw.

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
| `termination` | string | `accepted`, `max_tokens_exhausted`, `premature_eos` |
| `generated_tokens` | int? | nil on abnormal termination (loop throws before counting) |
| `latency_ms` | int | wall clock around the guided loop |
| `memory_footprint_bytes` | int64? | `phys_footprint` at record time |
| `model_revision` | string | |
| `created_at` | ISO-8601 | |

## `benchmark.ndjson` — RecoveryBenchmarkV1

Written once per **labeled** session by `RecoveryBenchmarkWriter` (device) or
derived by `bricky-harness replay` (Mac; always tagged
`device_model: "replay:<mac>"`). The consumer contract is
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
`occlusion_condition`. Release rows must populate all of them (see the
scorer README for corpus-level requirements: ≥150 cases, ≥10 models,
variation coverage).

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
