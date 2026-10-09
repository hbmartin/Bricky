# Triad evaluation harness

This device-result harness is deliberately independent of Apple's Evaluations
framework and scores measurable outcomes directly; qualitative model-judge
scoring is unnecessary for known authored-step labels. (The language layer's
Evaluations suite, `BrickyLanguageEvaluations`, is a local development
tool for repair wording, not a gate; ADR 0017.)

`score_results.py` accepts mixed NDJSON keyed by an optional `kind` per row:

- `recovery` (default, `RecoveryBenchmarkV1`): top-1/top-3 accuracy, adjacent
  step confusion, insufficient rate, latency, and peak memory. Latency is
  bucketed by the required `estimator_method` field (ADR 0010) and each
  bucket is judged against its own budget:

  | `estimator_method` | meaning | median gate |
  | --- | --- | --- |
  | `geometric` | the geometric pass concluded; no weights loaded | 8 s |
  | `composite` | geometric ran, stepped aside, VLM concluded | 20 s |
  | `vlm` | no depth observation, so the VLM ran alone | 20 s |

  A `composite` row's latency covers **both** legs — the composite estimator
  owns the wall clock, because each underlying estimator times only itself.
  `model_revision` is informational (which weights or solver produced the
  ranking) and is never parsed to infer the method.

  A release corpus spans ≥ 6 legally usable authored models (a floor that
  is pending an owner decision between 6 and 10) with one row per fixture.
- `verification`: step-verifier verdicts against expected labels. The
  headline gate is the false-complete rate (≤ 2 %, printed first per
  ADR 0008), plus per-detectability precision/recall, undetectable
  abstention ≥ 95 %, uncertain-on-correct ≤ 15 %, and a 3 s latency median.
- `registration`: tracker fits against ground truth — convergence ≥ 95 % on
  unambiguous fixtures, ≤ 3 mm / ≤ 2° RMSE, ambiguity recall ≥ 90 % on
  deliberately symmetric fixtures (which never count against convergence).
  It also counts:
  - `unexpected_ambiguity_cases`, the other half of recall;
  - `pitch_off_cases`, poses that settled within 2 mm of a whole stud
    pitch at true yaw;
  - the lattice runner-up histogram.

  The synthetic lattice suite (`--suite lattice`) is where ambiguity is
  expected.
- `lattice_window` (ADR 0020, informational), from `bricky-harness
  lattice-rows`. It reports device windows' lattice margins, ambiguous
  frames and staged confusions, and every run prints `STUD_KEYPOINTS_ENTRY`:
  - **MET** when the one-sided 95% lower bound on lattice trouble is at
    least 5%;
  - **NOT_MET** when the upper bound is under 5%;
  - **UNMEASURED** otherwise, including with no rows at all.

  It needs at least 30 staged device windows from 3 sessions.
- `stud_labels` and `stud_label_capture` (SyntheticRGBD label output) are
  accepted and never scored.
- `shadow_check` (ADR 0018, informational): the Foundation Models advisor
  beside photo checks. It reports the advisor's standalone false-complete
  rate with its bound, and how many more negatives the ADR needs (149 at
  zero misses). It also reports what the only-toward-incomplete merge did:
  flips that caught a negative or lost a complete. Rows whose merge moved
  anything but a complete are refused. Release mode takes only staged
  device rows from a floor device, as for `vlm_check`.

Verification rows replayed with `--colour-term` also get an informational
`colour_term` block (ADR 0008 amendment): status counts, disagreements on
built steps, and agreements on negatives. It appears only when rows carry
colour.

`score_wording_ab.py` unblinds a repair-wording preference sheet
(`bricky-harness wording-sheet`) and runs an exact one-sided sign test.
MODEL PREFERRED takes at least five clean wins.

### Release mode and informational mode

**Unmeasured is not zero.** A gate with an empty denominator (no negatives,
no rows in a latency bucket, no ambiguity fixtures) is `UNMEASURED`, never a
perfect score.

- **Release mode (the default)** judges each rate gate on a one-sided 95 %
  Clopper–Pearson bound and each median-latency gate on a distribution-free
  order-statistic bound. RMSE gates need ≥ 20 converged fits. A required gate
  that is `UNMEASURED` fails, and so does a missing required kind
  (`--require-kinds`, default: recovery, verification and registration; it
  also accepts `vlm_check` and `shadow_check`, which must then be present but
  whose gates stay informational). There is no fixed row minimum:
  each gate's bound sets it, and `--explain-minimums` prints the zero-miss
  sample every gate implies — for example 149 negatives for the 2 %
  false-complete ceiling, and 59 rows for top-3 ≥ 0.95. A perfect 40/40
  demonstrates only ≈ 0.93.
- **Informational mode** (`--informational`, alias `--allow-small-corpus`)
  judges point estimates and only reports `UNMEASURED`. Use it for smoke data
  and CI trend lines, never for release decisions.

The false-complete headline always prints first, even when it could not be
measured. One `GATE` line per gate follows (status, point value, bound, n,
threshold), then the JSON report with a `gates` summary per kind. The
marginal precision/recall pair is `DORMANT` until the RGB support term
exists (ADR 0008): it is reported, but never required and never fails.

Boards have one layout authority, `RecoveryBoardLayoutV1` in
`Packages/RecoveryMLX/Sources/RecoveryEvidenceKit`, shared by the app and the
Mac harness: `bricky-harness recompose` rebuilds boards from evidence bundles,
and `bricky-harness synth-bundle` draws synthetic fixtures through it. The
Python tools here need nothing beyond the standard library.

## Phase 1 report (`phase1_report.py`)

One command turns exported Phase 1 bundles into every readout
(docs/PHASE1_RUNBOOK.md):

```sh
python3 -I phase1_report.py bundle-a/ bundle-b/ --work report/ [--strict]
```

It merges each session's device rows by kind (a session exported twice
counts once), scores each kind in release mode in its own run on the rows the
preflight accepts (never requiring registration rows, which the device does
not make), and scores everything informationally. It also prints the
readouts no other tool computes: `TERMINATION`, `ADMISSION` (the worst
measured model cost plus 25%, ADR 0003), `SHADOW_ADVISOR` per OS build,
`COLOUR_ENCODING`, `RELAY_AUX_EXTRACT`, `SEGMENTATION`, `RECORDER`, `COUNTS`
and the device `VERTICAL_CONTEST`. Synthetic bundles are flagged and kept
out of every device readout and release run. `report/phase1_report.json`
holds everything; `--strict` exits 1 when a release run failed or was
refused.

## Producing rows: the evidence workflow (ADR 0007)

Benchmark rows come from evidence bundles recorded on device and replayed on
a Mac — the app and the CLI share the same `MLXRecoveryRuntime`, grammar
constraints, and board layout.

1. On device: Storage ▸ Developer ▸ enable **Record recovery evidence** (and
   **Corpus collection mode** for release-corpus rows — declare the true step
   and conditions before capturing).
2. Run recoveries, Confirm, then Storage ▸ Developer ▸ Evidence Sessions ▸
   select ▸ Export, and AirDrop the zip to your Mac.
3. On the Mac:

```sh
unzip bricky-evidence-*.zip -d bundle
hf download mlx-community/Qwen3-VL-4B-Instruct-4bit \
  --revision 2fd8dacbdb8f1e54b8c005f081ec5bf79c56376b --local-dir model

swift run --package-path Packages/RecoveryMLX bricky-harness \
  replay --bundle bundle --model-dir model \
  --model-revision 2fd8dacbdb8f1e54b8c005f081ec5bf79c56376b --out results.ndjson
uv run python score_results.py results.ndjson --allow-small-corpus
```

Device-recorded `benchmark.ndjson` rows inside the bundle are the *device*
numbers; `bricky-harness replay` rows carry `device_model: "replay:<mac>"`.
The tag alone protects nothing — replay copies the staged declaration's
`physical_case` and `legal_use_confirmed` verbatim — so release mode
enforces it: every release row's `device_model` must be an admitted
`iPhone<≥18>,<n>` identifier, each `fixture_id` may appear once (a device row
and its own replay share the session UUID), and challenge or
expected-failure rows are refused. Verification and registration rows
additionally need `provenance: "device"`, which no producer emits yet, so
those kinds fail release mode honestly until one exists.

### A/B experiments

Replay each arm to its own output file, then compare them paired:

```sh
python3 compare_arms.py --control control.ndjson --variant feed_all.ndjson
```

`compare_arms.py` pairs passes by trace; sessions, checks and replayed
verification windows by fixture. `--primary` picks the accuracy that
decides: `pass_top1` (VLM arms), `session_top1` (geometric recovery),
`check_correct` (check-target or advisor arms) or `verification_correct`
(`--colour-term` arms).
- **Accuracy:** it runs an exact McNemar test, Holm-corrected across
  variants. With no losses it takes at least 6 wins to reach p < 0.05.
- **Latency:** it reports the paired latency ratio; differences under 5%
  count as none.
- **Slot bias:** it shows the slot-letter histogram, chosen versus truth.
- **Verdict:** it names a variant a Mac-replay flip candidate only when the
  insufficient, check false-complete and verification false-complete rates
  do not rise. Device rows are still required before a default changes
  (ADR 0010 amendment).
- **Refusals:** arms that ran different `model_revision`s
  (`--allow-mixed-revisions` overrides), and an adapter arm without
  `--restrict split_manifest.json` (ADR 0019).

### Training pairs (ADR 0019)

```sh
python3 export_training_pairs.py bundle [bundle ...] --out pairs [--copy-images]
```

Writes LoRA training pairs: one per rank trace whose board held the truth,
with the exact stored board, the verbatim prompt, and a target that starts
with the probe's prefix and names the truth slot first. Train and test are
split by authored model and physical build, transitively, into
`train.jsonl` and `test.jsonl`, with `split_manifest.json` for
`compare_arms.py --restrict` and `manifest.json` recording inputs,
exclusions and the leakage check. It refuses unlabeled, judged, `replay:`
and `synthetic:` sessions, sessions without legal-use confirmation, fewer
than 150 labelled sessions, fewer than two split components per side, and
any identity found on both sides. `--smoke` accepts synthetic bundles and
marks every pair smoke, for the pipeline test only. The trainer lives in
`Tools/Training/`.


Replay is a Mac-vs-Mac instrument (greedy guided decoding is deterministic per
platform, but iOS↔macOS Metal kernels can flip near-tie argmax). Compare a
baseline replay against a variant replay of the same bundle:

```sh
swift run --package-path Packages/RecoveryMLX bricky-harness \
  replay --bundle bundle --model-dir model \
  --model-revision 2fd8dacbdb8f1e54b8c005f081ec5bf79c56376b --out baseline.ndjson
swift run --package-path Packages/RecoveryMLX bricky-harness \
  replay --bundle bundle --model-dir model \
  --model-revision 2fd8dacbdb8f1e54b8c005f081ec5bf79c56376b \
  --prompt-file variant-prompt.txt --out variant.ndjson
uv run python score_results.py baseline.ndjson --allow-small-corpus
uv run python score_results.py variant.ndjson --allow-small-corpus
```

`--recompose` rebuilds boards from raw captures + tiles through the shared
layout (for layout experiments), `--max-tokens` overrides the rank budget, and
`--all-passes` replays every hierarchical pass instead of only the finalists,
and `--vote` picks the finalist vote rule (`borda_dedup`, the app default, or
`borda_legacy`, which counts repeated slots as the app did before 2026-09).
Per-call results (including `matches_device`) land beside the output as
`<out>.traces.ndjson`. `--dry-run` validates a bundle without loading weights.

Device runs append one JSON object per line to an NDJSON file. Then run:

```sh
uv sync --frozen
uv run python score_results.py device-results.ndjson
```

`fixtures/example-device-results.ndjson` is schema/scorer smoke data only. It is
not physical evidence and must never be included in release-gate metrics. For
smoke data such as the example fixture, pass `--informational`:

```sh
uv run python score_results.py fixtures/example-device-results.ndjson --informational
```

The release corpus must contain one row per physical fixture from at least 6
legally usable authored models, with adjacent steps, varied lighting, angles,
and occlusion represented explicitly, and enough rows for every required
gate's bound to clear its threshold. Release-gate runs must never use
`--informational`.

Every release row therefore also includes `physical_case: true`, a stable
`authored_model_id`, `legal_use_confirmed: true`, and non-empty
`lighting_condition`, `capture_angle`, and `occlusion_condition` labels. Each
row must show a step adjacent to `expected_step_index`, either in
`candidate_slots` (the VLM board) or in `scored_step_ids` (the steps the
geometric leg fitted, since a geometric row has no board); the scorer requires at least two distinct lighting and occlusion labels and
at least 6 distinct authored model IDs. `capture_angle` is the comma-joined
set of views the session captured (normally `left,center,right`) and must
include `center` plus a side view. Viewing variety comes from
`capture_elevation_degrees` instead — the center capture's measured angle
below the horizon — and the corpus must span at least two of the bands
below 35°, 35–60°, and above 60° (RECONSTRUCTED edges). `top_step_index`
may be omitted or null only when `certainty` is `insufficient`.
