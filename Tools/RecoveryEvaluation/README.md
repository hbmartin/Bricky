# Triad evaluation harness

This device-result harness is deliberately independent of Apple's Evaluations
framework and scores measurable outcomes directly; qualitative model-judge
scoring is unnecessary for known authored-step labels.

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

### Release mode and informational mode

**Unmeasured is not zero.** A gate with an empty denominator (no negatives,
no rows in a latency bucket, no ambiguity fixtures) is `UNMEASURED`, never a
perfect score.

- **Release mode (the default)** judges each rate gate on a one-sided 95 %
  Clopper–Pearson bound and each median-latency gate on a distribution-free
  order-statistic bound. RMSE gates need ≥ 20 converged fits. A required gate
  that is `UNMEASURED` fails, and so does a missing required kind
  (`--require-kinds`, default: all three). There is no fixed row minimum:
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

`make_board.py` reproduces the app's bounded 1024×1024 single-image layout for
offline fixtures. Candidate order is the A–H slot map stored in
`RecoveryBenchmarkV1`:

```sh
uv run python make_board.py physical.jpg step-0.png step-8.png step-16.png \
  --step-labels 0 8 16 --out boards/case-001.jpg
```

> **Deprecated as layout authority.** The board geometry now has a single
> authoritative implementation shared by the app and the Mac harness:
> `RecoveryBoardLayoutV1` in `Packages/RecoveryMLX/Sources/RecoveryEvidenceKit`.
> Use `bricky-harness recompose` to rebuild boards from evidence bundles;
> `make_board.py` remains only for synthetic fixtures and is not kept in
> lockstep with the app.

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
row's `candidate_slots` must contain a step adjacent to `expected_step_index`;
the scorer requires at least two distinct lighting and occlusion labels and
at least 6 distinct authored model IDs. `capture_angle` is the comma-joined
set of views the session captured (normally `left,center,right`) and must
include `center` plus a side view. Viewing variety comes from
`capture_elevation_degrees` instead — the center capture's measured angle
below the horizon — and the corpus must span at least two of the bands
below 35°, 35–60°, and above 60° (RECONSTRUCTED edges). `top_step_index`
may be omitted or null only when `certainty` is `insufficient`.
