# bricky-harness: Mac replay, recompose, and A/B methodology

Status: implemented. Last revised 2026-08-04.

`bricky-harness` is a macOS CLI (`Packages/RecoveryMLX/Sources/
bricky-harness`) that replays exported evidence bundles through the **exact
device inference stack**: the same `MLXRecoveryRuntime` actor, the same
precompiled grammar constraints, the same 1024×1024 input resize, and the
same `RecoveryBoardLayoutV1` board geometry. It exists so recovery failures
reproduce on a Mac and so prompt/layout/token changes are measured, not
eyeballed.

See [EVIDENCE_BUNDLE_FORMAT.md](EVIDENCE_BUNDLE_FORMAT.md) for what a bundle
contains and [Tools/RecoveryEvaluation/README.md](../Tools/RecoveryEvaluation/README.md)
for the scorer's corpus rules.

## Setup

```sh
# Weights: the pinned revision from ADR 0013 (also printed by --help)
hf download mlx-community/Qwen3-VL-4B-Instruct-4bit \
  --revision 2fd8dacbdb8f1e54b8c005f081ec5bf79c56376b --local-dir model

# The bundle arrives from the device via share sheet / AirDrop
unzip bricky-evidence-*.zip -d bundle
```

Build and run from the repo root with
`swift run --package-path Packages/RecoveryMLX bricky-harness …`. The
package builds with no Xcode project involvement; CI compiles and tests it
on every PR (`harness-macos` job) without weights.

## `replay`

```sh
swift run --package-path Packages/RecoveryMLX bricky-harness replay \
  --bundle bundle --model-dir model --model-revision <sha> --out results.ndjson
```

`--model-revision` names the weights actually in `--model-dir` and is recorded
as `model_revision` on every replay row — never the source session's revision,
which may differ in an A/B.

Behavior:

1. Validates the bundle (`EvidenceBundleReader.validate`) and refuses to run
   on structural issues. `--dry-run` stops here — no weights needed, which
   is what CI exercises.
2. For each session, replays its rank traces — by default only the
   `finalist` passes (the ones that vote); `--all-passes` replays the
   `broad`/`narrowing`/`narrow` passes too. `check` traces are never
   replayed.
3. Each replay calls `rankWithTrace` with the recorded prompt, the recorded
   board image, and `candidateCount` from the recorded slot map — the same
   dynamic grammar the device compiled.
4. For **labeled** sessions that have replayable finalist rank traces,
   aggregates the replayed finalist outputs into a `RecoveryBenchmarkV1` row
   using a mirror of the estimator's Borda scoring and cross-view certainty
   (leader agreement 3 → high, 2 → medium; fewer than two voting views →
   insufficient). Both conditions are required: unlabeled sessions replay but
   emit no benchmark row, and a labeled **geometric-only** session (fits but
   no rank traces) emits none either because geometric replay does not exist
   yet — the CLI reports each such skip explicitly so corpus counts account
   for those sessions.
5. Writes benchmark rows to `--out` and every per-call result to
   `<out>.traces.ndjson`.

Row provenance is enforced structurally: replay rows carry
`device_model: "replay:<mac-identifier>"` and `latency_ms` equal to the sum
of the *replayed* finalist latencies, so Mac numbers can never masquerade as
device rows in a release corpus. The device's own numbers are the
`benchmark.ndjson` files already inside the bundle.

The traces sidecar (`ReplayTraceResult`) carries per call: `raw_output`,
`decode_error`, `termination`, `latency_ms`, the recorded
`device_raw_output`, and `matches_device` — the quickest signal for whether
a device failure reproduces at all.

### A/B knobs

| Flag | Effect |
| --- | --- |
| `--prompt-file f` | Replace every recorded rank prompt with the file's contents |
| `--max-tokens N` | Override the rank token budget (device default is 192) |
| `--recompose` | Rebuild each board from the raw capture + tiles through `RecoveryBoardLayoutV1` instead of replaying the stored board image (layout experiments) |
| `--all-passes` | Replay the full hierarchy, not only finalists |

## `recompose`

```sh
swift run --package-path Packages/RecoveryMLX bricky-harness recompose \
  --bundle bundle --trace <trace-uuid> --out board.jpg
```

Rebuilds one trace's board from its capture and tiles for visual layout
debugging. Tiles are placed in slot order; step labels derive from the
recorded `candidate_step_indices` (internal index + 1, so step zero renders
as "Step 0").

## Workflows

### Diagnosing a device failure

1. On device: Storage ▸ Developer ▸ enable **Record recovery evidence**;
   reproduce the bad recovery (no need to Confirm — unlabeled sessions are
   kept on purpose); export and AirDrop the bundle.
2. Read the failure directly from `traces.ndjson`: `termination`,
   `decode_error`, and `raw_output` usually identify the layer (grammar,
   truncation, ranking quality) without running anything.
3. Replay with `--all-passes` and check `matches_device` — if the failure
   reproduces on the Mac, iterate there; if not, it is device-specific
   (memory pressure, thermal, Metal argmax ties).

### Producing benchmark rows (CONTRIBUTING requirement)

MLX or AR changes require physical-device benchmark rows. Enable **Corpus
collection mode** as well, declare the true step and conditions before
capturing, run the recovery, Confirm, export. The bundle's own
`benchmark.ndjson` rows are the *device* numbers; replay rows are the Mac
numbers. Score either with:

```sh
uv run python Tools/RecoveryEvaluation/score_results.py results.ndjson --allow-small-corpus
```

(Release-gate runs must never pass `--allow-small-corpus`.)

### A/B experiments

Baseline and variant are two replays **of the same bundle** on the same Mac:

```sh
bricky-harness replay --bundle bundle --model-dir model --model-revision <sha> \
  --out baseline.ndjson
bricky-harness replay --bundle bundle --model-dir model --model-revision <sha> \
  --prompt-file variant-prompt.txt --out variant.ndjson
# score both, compare
```

CONTRIBUTING makes this mandatory for prompt or board-layout changes.

## Determinism and parity caveats

- **Replay is a Mac-vs-Mac instrument.** Greedy guided decoding is
  deterministic *per platform*, but iOS and macOS Metal kernels can flip
  near-tie argmax. Compare replays against replays; treat
  `matches_device` as a reproduction signal, not a parity guarantee.
- `--recompose` boards are not guaranteed byte-identical to device boards:
  the device composes through the same kit layout, but JPEG re-encode of
  tiles and any pre-kit-era bundles differ. Recompose-vs-stored is itself an
  A/B axis.
- Replay certainty/Borda aggregation mirrors the estimator but operates only
  on the recorded finalist set; it cannot re-run the adaptive narrowing that
  chose those finalists unless you inspect `--all-passes` traces manually.
