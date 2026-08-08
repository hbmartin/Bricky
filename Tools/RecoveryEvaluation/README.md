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

  The physical release corpus requires ≥ 40 distinct fixtures across ≥ 6
  legally usable models.
- `verification`: step-verifier verdicts against expected labels. The
  headline gate is the false-complete rate (≤ 2 %, printed first per
  ADR 0008), plus per-detectability precision/recall, undetectable
  abstention ≥ 95 %, uncertain-on-correct ≤ 15 %, and a 3 s latency median.
- `registration`: tracker fits against ground truth — convergence ≥ 95 % on
  unambiguous fixtures, ≤ 3 mm / ≤ 2° RMSE, ambiguity recall ≥ 90 % on
  deliberately symmetric fixtures (which never count against convergence).

Every kind present enforces the release corpus minimum unless
`--allow-small-corpus` is passed: at least 40 rows per kind (`recovery`
counts distinct fixture IDs and additionally requires at least 6 legally
usable authored models).

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
  replay --bundle bundle --model-dir model --out results.ndjson
uv run python score_results.py results.ndjson --allow-small-corpus
```

Device-recorded `benchmark.ndjson` rows inside the bundle are the *device*
numbers; `bricky-harness replay` rows carry `device_model: "replay:<mac>"` so
they can never masquerade as device rows in a release corpus.

### A/B experiments

Replay is a Mac-vs-Mac instrument (greedy guided decoding is deterministic per
platform, but iOS↔macOS Metal kernels can flip near-tie argmax). Compare a
baseline replay against a variant replay of the same bundle:

```sh
swift run --package-path Packages/RecoveryMLX bricky-harness \
  replay --bundle bundle --model-dir model --out baseline.ndjson
swift run --package-path Packages/RecoveryMLX bricky-harness \
  replay --bundle bundle --model-dir model --prompt-file variant-prompt.txt \
  --out variant.ndjson
uv run python score_results.py baseline.ndjson --allow-small-corpus
uv run python score_results.py variant.ndjson --allow-small-corpus
```

`--recompose` rebuilds boards from raw captures + tiles through the shared
layout (for layout experiments), `--max-tokens` overrides the rank budget, and
`--all-passes` replays every hierarchical pass instead of only the finalists.
Per-call results (including `matches_device`) land beside the output as
`<out>.traces.ndjson`. `--dry-run` validates a bundle without loading weights.

Device runs append one JSON object per line to an NDJSON file. Then run:

```sh
uv sync --frozen
uv run python score_results.py device-results.ndjson
```

`fixtures/example-device-results.ndjson` is schema/scorer smoke data only. It is
not physical evidence and must never be included in release-gate metrics. The
scorer refuses corpora below the release minimum (40 rows per kind — distinct
fixtures for recovery, which also needs 6 authored models); for smoke data such
as the example fixture, pass `--allow-small-corpus`:

```sh
uv run python score_results.py fixtures/example-device-results.ndjson --allow-small-corpus
```

The release corpus must contain at least 40 distinct physical fixtures from at
least 6 legally usable authored models, with adjacent steps, varied lighting,
angles, and occlusion represented explicitly. Release-gate runs must never use
`--allow-small-corpus`.

Every release row therefore also includes `physical_case: true`, a stable
`authored_model_id`, `legal_use_confirmed: true`, and non-empty
`lighting_condition`, `capture_angle`, and `occlusion_condition` labels. Each
row's `candidate_slots` must contain a step adjacent to `expected_step_index`;
the scorer requires at least two distinct labels for each variation dimension
and at least 6 distinct authored model IDs. `top_step_index` may be omitted or
null only when `certainty` is `insufficient`.
