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
   `broad`/`narrowing`/`narrow` passes too. `check` traces are replayed
   only with `--checks` (below).
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

Row provenance: replay rows carry `device_model: "replay:<mac-identifier>"`
and a `latency_ms` equal to the sum of every replayed call, with
`latency_scope` saying which calls those were: `inference_all_passes` under
`--all-passes`, otherwise `inference_finalists_only`. They
copy the staged declaration's physical and legal-use flags verbatim, so the
tag is what separates them from device rows, and `score_results.py` release
mode enforces it: only admitted `iPhone<≥18>,<n>` identifiers are accepted,
and a fixture may appear once. The device's own numbers are the
`benchmark.ndjson` files already inside the bundle.

The traces sidecar (`ReplayTraceResult`) carries, per call:
- `raw_output`, `decode_error`, `termination`, `latency_ms`;
- the recorded `device_raw_output`;
- `matches_device`: the same decision (status and ranking), ignoring
  whitespace. It is the quickest signal for whether a device failure
  reproduces at all;
- `matches_device_raw`: byte identity;
- `variant` / `variant_id`;
- the decoded `decision`;
- `outcome`: `truth_slot`, `chosen_slot`, `truth_in_candidates`,
  `top1_correct`. These make rows pairable by trace for an A/B, and give
  the slot-bias histogram;
- the decoder's `inference` telemetry and `readouts`.

### A/B knobs

| Flag | Effect |
| --- | --- |
| `--prompt-file f` | Replace every recorded rank prompt with the file's contents |
| `--max-tokens N` | Override the rank token budget (device default is 192) |
| `--recompose` | Rebuild each board from the raw capture + tiles through `RecoveryBoardLayoutV1` instead of replaying the stored board image (layout experiments) |
| `--all-passes` | Replay the full hierarchy, not only finalists |
| `--vote borda_dedup\|borda_legacy` | Finalist vote rule (`RecoveryVote`, shared with the app). `borda_dedup` is the app default; `borda_legacy` counts repeated slots as the app did before 2026-09 |
| `--checks` | Also replay step-check traces into `<out>.checks.ndjson` as `vlm_check` rows. The scorer prints their false-complete rate; the expected verdict comes from the session's labeled step count. Staged check sessions (corpus collection, declared short of the checked step) are the negatives |
| `--check-target guide_camera\|registered` | Replay checks against that target. A check recorded at the other target uses its `alternate_tile_relative_paths` tile and needs `--recompose`; a check with no tile for the target (every check outside the AR guide, for `registered`) has no row in that arm |
| `--arm NAME`, `--variant JSON` | Record an arm label; `--variant` sets the whole `RecoveryInferenceVariant` at once (overriding `--decode`/`--vote`). Rows carry `variant_id` |
| `--slot-order rotated`, `--board v2`, `--labels slot` | Rebuild boards (needs `--recompose`) with finalists rotated across views, the V2 layout (≤ 4 tall finalist tiles; side-by-side check), or slot-only labels (hides step numbers from the model) |
| `--prompt-style baseline\|dynamic_range`, `--image-side N` | Replace recorded prompts (`dynamic_range` names only the slots on the board); resize boards to N px before the vision encoder |
| `--unique-slots` | Mask slot letters already in the ranking (`unique_slots`); needs the forked decoder |
| `--scoring generate\|probe` | `probe` reads the decision's probabilities from one prefill over a canonical answer prefix instead of generating JSON; pair with `--vote logprob` to pool views by log probability |
| `--adapter DIR` | Apply a converted LoRA adapter unfused over `--model-dir` (ADR 0019). The adapter is refused unless its config spells out rank, scale and keys and carries a `bricky` block whose `base_model_revision` equals `--model-revision`, its tensors cover exactly the model's last `num_layers` decoder layers, and its dtype is the model's. Rows record `adapter=<name>@<sha12>` in `variant_id`; a smoke adapter prints a warning |
| `--decode legacy\|upstream\|feed_all` | Decoder (`RecoveryGuidedDecoder`). `legacy` is the app default and byte-identical to the pinned loop (`upstream`); `feed_all` feeds every sampled token to the KV cache. Replay traces record the mode, decode telemetry, and the model's distribution at small-legal-set decisions (`readouts`) |

## `recompose`

```sh
swift run --package-path Packages/RecoveryMLX bricky-harness recompose \
  --bundle bundle --trace <trace-uuid> --out board.jpg
```

Rebuilds one trace's board from its capture and tiles for visual layout
debugging. Tiles are placed in slot order; step labels derive from the
recorded `candidate_step_indices` (internal index + 1, so step zero renders
as "Step 0").

## `wording-sheet`

```sh
swift run --package-path Packages/RecoveryMLX bricky-harness wording-sheet \
  --bundle bundle --out-sheet sheet.csv --out-key key.csv
python3 Tools/RecoveryEvaluation/score_wording_ab.py --sheet sheet.csv --key key.csv
```

Builds the blinded preference sheet for repair wording (ADR 0017) from the
device's `wording.ndjson`. Each pair is an accepted model sentence and the
template it replaced, rated once. The order and the A/B placement are
seeded, so a sheet can be rebuilt. Give the sheet to the rater and keep the
key. The scorer runs an exact one-sided sign test; the default flips only
on MODEL PREFERRED from device pairs.

## `fm-shadow`

```sh
swift run --package-path Packages/RecoveryMLX bricky-harness fm-shadow \
  --bundle bundle --out fm.ndjson
```

Runs every labeled photo check in a bundle through the Foundation Models
advisor (ADR 0018). It writes `shadow_check` rows to `--out`, and the
advisor's standalone verdicts as `vlm_check` rows to `<out>.checks.ndjson`,
so `compare_arms.py --primary check_correct` pairs them with a VLM replay's
`--checks` arm. It needs macOS 27 with Apple Intelligence on. It is
informational: a Mac is not the phone's model tier, and release mode
refuses replay rows.

## `adapter-template`

```sh
swift run --package-path Packages/RecoveryMLX bricky-harness adapter-template \
  --model-dir model --model-revision <sha> --out zero-b [--rank 8 --scale 20 --layers N]
```

Loads the pinned model and writes what a converted adapter for it must look
like: `template.json` lists every tensor's name and shape
(`language_model.model.layers.<n>.<key>.lora_a` is `[in, rank]`, `lora_b` is
`[rank, out]`) and the dtype it must be stored in (BF16 for the pinned 4-bit
model). `convert_adapter.py` checks its output against it. The same directory
is a zero-B smoke adapter: B is zero in the model's dtype, so replaying it
must reproduce the baseline byte for byte. That is the check that the adapter
path adds nothing of its own (`RecoveryAdapterSmokeTests`). An adapter stored
in float32 would not: `QLoRALinear` adds `scale·x·A·B` to the layer's output,
and a float32 term promotes every later activation.

## `synth-bundle`

```sh
swift run --package-path Packages/RecoveryMLX bricky-harness synth-bundle \
  --out smoke-bundle --authored-models 4 --builds-per-model 2 --sessions 6 --seed 7
```

Writes a synthetic smoke bundle for the LoRA pipeline's end-to-end test
(ADR 0019): boards of stacked coloured blocks, one more block per step, as in
the weights-gated tests. Each session is staged at a known step with one
finalist board of up to four candidate steps around it, in a seeded slot
order, with the verbatim baseline rank prompt and grammar. Authored models
differ in palette and physical builds in block width, so the exporter's split
has something to split. The same seed writes the same bytes. Its device model
is `synthetic:bricky-harness`: a pipeline fixture, not a sensor model, refused
by every release and training path.

## `lattice-rows`

```sh
swift run --package-path Packages/RecoveryMLX bricky-harness lattice-rows \
  --bundle bundle --out lattice.ndjson
python3 Tools/RecoveryEvaluation/score_results.py lattice.ndjson --informational
```

Writes one `lattice_window` row per verification window: frame counts by
registration state, the margins of the frames where the lattice sweep ran,
how often each alternative set the margin, the verifier's ±1-stud contests,
and the staged truth. No model and no weights. The scorer's `lattice_window`
section summarises device rows, and every run prints the stud-keypoint
entry line (ADR 0020):

```
STUD_KEYPOINTS_ENTRY UNMEASURED (0 device windows, need 30)
```

Only device windows (an iPhone, not a replay or synthetic session) that
closed on a staged `complete` or `shifted_one_stud` build count. A window is
lattice trouble when the verifier refused for `poseAmbiguous`, at least half
its frames were ambiguous, a complete build was called misplaced, or a
shifted one complete. With at least 30 such windows from 3 sessions, the
criterion is MET when the one-sided 95% lower bound on that rate is at least
5%, and NOT_MET when the upper bound is under 5% (about 59 clean windows).
Anything else reads UNMEASURED with its reason; it never gates a release.

## Stud labels for photo captures (SyntheticRGBD)

```sh
SyntheticRGBD model.ldr --ldraw-root ldraw --out labels.ndjson \
  --stud-labels-bundle bundle [--include-confirmed]
```

Not a harness command: it needs the instruction model and the part pack,
which bundles never carry, so it runs in SyntheticRGBD beside
`--replay-bundle`, against the same files that were imported (sessions of
another model are skipped). For each AR photo capture it writes one
`stud_label_capture` row (provenance `pseudo_registered`):
- **What is labelled:** the authored top studs of what the staged
  declaration says was built.
- **How they are placed:** projected through the locked model pose the
  photo was taken under, onto the stored upright photo (`x`, `y`
  normalized).
- **Which are visible:** visibility comes from a stud-ID render at the
  photo's own camera.
- **What is written:** the image is referenced by path, never copied.

`StudLabelPolicy` refuses, and records why: no staged truth (confirmed
sessions only with `--include-confirmed`), no locked pose, no registration
snapshot, not locked, or a lattice margin under 1.5.

A pose locked one pitch off would label every stud one pitch off,
consistently and silently, so these are pseudo-labels: check them by eye
before anything trains on them (ADR 0020).

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

`compare_arms.py` refuses two kinds of comparison before computing anything:
- **Different weights.** Arms whose `model_revision`s differ (session, check
  and, since 2026-10-07, trace sidecar rows all carry it) are refused unless
  `--allow-mixed-revisions`, for a pin bump measured on purpose. Older trace
  sidecars without the field only warn.
- **An adapter scored on its own training data.** An arm whose `variant_id`
  names an `adapter=` (ADR 0019) is refused unless `--restrict
  split_manifest.json` limits every arm to the exporter's held-out test
  sessions.

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
