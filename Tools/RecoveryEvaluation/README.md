# Recovery evaluation harness

This device-result harness is deliberately independent of Apple's Evaluations
framework: Bricky supports iOS 17, while Evaluations is new in the 27 cycle and
does not back-deploy. ✅ VERIFIED by the captured Xcode 27 framework interface.

The harness scores measurable outcomes directly: top-1/top-3 accuracy, adjacent
step confusion, insufficient rate, median/p95 latency, and peak memory. This is
the quantitative path; qualitative model-judge scoring is unnecessary for a
known authored-step label. ✅ VERIFIED: use code metrics when the property is
measurable, and inspect distributions rather than trusting a single pass rate.

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
hf download mlx-community/Qwen2.5-VL-3B-Instruct-4bit \
  --revision 46d4cf06a06ffc1a766c214174f9cbed2f45bcab --local-dir model

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
scorer refuses corpora smaller than 150 rows; for smoke data such as the example
fixture, pass `--allow-small-corpus`:

```sh
uv run python score_results.py fixtures/example-device-results.ndjson --allow-small-corpus
```

The release corpus must contain at least 150 physical cases from at least 10
legally usable authored models, with adjacent steps, varied lighting, angles,
and occlusion represented explicitly. Release-gate runs must never use
`--allow-small-corpus`.

Every release row therefore also includes `physical_case: true`, a stable
`authored_model_id`, `legal_use_confirmed: true`, and non-empty
`lighting_condition`, `capture_angle`, and `occlusion_condition` labels. Each
row's `candidate_slots` must contain a step adjacent to `expected_step_index`;
the scorer requires at least two distinct labels for each variation dimension
and at least 10 distinct authored model IDs. `top_step_index` may be omitted or
null only when `certainty` is `insufficient`.
