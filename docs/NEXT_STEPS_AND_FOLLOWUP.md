# Evidence harness: next steps and follow-up work

Last revised 2026-08-04. Companion to
[EVIDENCE_HARNESS_OVERVIEW.md](EVIDENCE_HARNESS_OVERVIEW.md).

The harness shipped with a deliberate sequencing decision: **instrumentation
plus two provably-safe fixes only** (dynamic rank grammar, rank token
headroom). Everything that could change model behavior in unmeasured ways
was deferred until it can be run as a measured A/B on real evidence bundles.
This file is the ledger of that deferred work, the items that require a
physical device, and the longer-term training path.

## 1. Owed on a physical device (blocking, in order)

These cannot be done in this repo alone; each needs a LiDAR iPhone.

1. **Collect the first real evidence bundle.** Enable both developer
   toggles, run staged recoveries on a known physical build, Confirm,
   export, AirDrop, unzip, `bricky-harness replay`, score. This is the
   end-to-end verification of the whole pipeline — until it happens, the
   only replayed bundle is the synthetic test fixture. Watch for: capture
   copy timing, share-sheet zip size, and whether `matches_device` holds on
   accepted generations.
2. **Device benchmark row for the shipped fixes.** CONTRIBUTING requires
   physical-device benchmark rows for MLX changes; the dynamic-grammar and
   `rankMaxTokens: 96 → 192` changes shipped on the strength of static
   analysis (closing bias previously began mid-array at token 32). Confirm
   on device: `termination` should be `accepted` on effectively all rank
   traces, and `max_tokens_exhausted` rows should disappear.
3. **Board-parity A/B for the composer change.** `RecoveryBoardLayoutV1`
   changed what the model sees in two ways: boards are now exactly
   1024×1024 (the old UIKit composer rendered at screen scale, 2–3× larger
   on disk, downscaled at inference) and labels render in Menlo-Bold via
   CoreText (previously the device font path). Both are believed benign and
   neither was measured. Run: one bundle, `replay --out stored.ndjson`
   versus `replay --recompose --out recomposed.ndjson`, compare scores and
   per-trace rankings.
4. **Admission-floor profiling (ADR 0003 / CONTEXT gap).** The 5.5 GB
   admission threshold is still the conservative placeholder. Profile the
   production-sized warm-up with AR, scene mesh, and the ICP tracker active;
   set the floor to measured worst-case `phys_footprint` peak + 25%. The
   evidence rows' `memory_footprint_bytes` now provide exactly this number
   per inference call.

## 2. Deferred, measured A/Bs (agreed 2026-08-03 — do not ship without data)

Each was explicitly deferred during the design session because the harness
now makes it cheaply measurable. Method for all of them: baseline replay vs
variant replay of the *same* bundle (see
[EVIDENCE_REPLAY_AND_AB.md](EVIDENCE_REPLAY_AND_AB.md)); ship only what
scores better.

| Candidate | Hypothesis | How to measure |
| --- | --- | --- |
| Portrait aspect-fill crop | The 992×420 physical strip center-crops portrait captures, cutting off the top/bottom of the build ("decapitation") | Layout variant in `RecoveryBoardLayoutV1` + `--recompose` A/B |
| Prompt rewrites | Rank prompt hardcodes "A–H" even when fewer slots exist (the grammar is now dynamic but the wording is not); per-pass prompts may beat one generic prompt | `--prompt-file` A/B per variant |
| Check token budget | `checkMaxTokens: 48` puts the whole check generation inside the 64-token closing-bias soft zone from token 0 | Needs a check-replay path first (see §4), then `--max-tokens` A/B |
| Finalist selection | The ±1-neighbor finalist set and center-capture funnel may structurally exclude the true step when the narrow pass is off by more than one | `--all-passes` traces quantify how often the truth was outside the finalist set before any redesign |
| Recompose vs stored boards | JPEG re-encode of tiles through the kit should be visually irrelevant | Same-bundle stored-vs-recomposed replay (doubles as item 1.3) |

## 3. Corpus goals

- **Release gate (VLM recovery):** ≥150 physical cases from ≥10 legally
  usable authored models, adjacent-step candidates present, lighting/angle/
  occlusion each with ≥2 distinct labels, scored without
  `--allow-small-corpus`. Gates: top-3 ≥ 0.95, top-1 ≥ 0.80, composite
  median ≤ 20 s. Currently: **zero rows**.
- **Triad physical corpus (CONTEXT gap):** ≥40 staged fixtures across ≥6
  models for the registration/verification gates — a distinct corpus with
  its own producer (geometric rows carry `estimator_method: geometric`),
  but the same staged-fixture declarations and scorer.
- **Failure library:** unlabeled sessions are kept on purpose; a growing set
  of reproducible-on-Mac failure bundles is the raw material for the A/B
  table above. Purge caps (40 sessions / 2 GB) mean interesting sessions
  should be exported promptly.

## 4. Harness engineering follow-ups (small, unordered)

- **Record geometric recovery attempts.** Since geometric-first recovery
  landed (ADR 0010), the VLM estimator is the fallback; evidence capture
  currently records only VLM calls (`RecoveryPassKind` has no geometric
  kind). A future session/trace extension covering geometric fits would let
  one bundle explain *both* stages of a composite recovery. Requires a
  `trace_version`/`session_version` discussion — additive optional fields
  may suffice.
- **Check-trace replay.** `bricky-harness replay` skips `check` traces
  entirely; a `--checks` mode replaying them against `checkStepWithTrace`
  would unlock the check-token-budget A/B in §2.
- **Bundle validation depth.** `EvidenceBundleReader.validate` verifies file
  existence, not image decodability — a corrupt JPEG passes `--dry-run` and
  fails mid-replay. Consider an opt-in `--verify-images` pass.
- **Export ergonomics.** Consider a size warning before staging very large
  exports (AirDrop over ~500 MB gets slow), and surfacing recorder write
  failures in `EvidenceSessionsView` (recording is deliberately best-effort
  and silent today; the session list only shows what was written).
- **`make_board.py` retirement.** Deprecated as layout authority but still
  used for synthetic fixtures; once synthetic fixtures go through
  `bricky-harness recompose` or the kit directly, delete it.

## 5. Training path (after eval is trustworthy)

Decision from the design session: **eval first, training-ready capture** —
fine-tuning is pointless until pipeline bugs are ruled out as the accuracy
ceiling. Prerequisites before any training run:

1. The §2 A/B table resolved — prompt/layout/token issues fixed or excluded.
2. ≥150 *labeled* cases (staged + confirmed) in the store, exported.
3. A stable eval baseline from the release-corpus scorer to measure lift.

Then: Apple Foundation Models custom adapters are discontinued in OS 27, so
the path is **mlx-vlm (Python) LoRA** on the pinned Qwen3-VL revision. The
bundle format was designed for this: per-candidate tile renders, exact
boards, prompts, and grammar schemas are all present, so training pairs
(board image + prompt → correct slot ranking) can be generated from bundles
without re-rendering. Keep the adapter evaluation on the same
`score_results.py` gates; a fine-tuned model is just another A/B variant to
the harness.

## 6. Format-evolution reminders

- New fields in interchange types: add as optional, snake_case CodingKeys
  spelled out, no version bump.
- Semantic changes: bump the specific version stamp
  (`trace_version`/`session_version`/`bundle_version`) and teach
  `EvidenceBundleReader.validate` plus the kit tests to reject the old one
  loudly.
- `RecoveryBenchmarkV1` changes must move in lockstep with
  `score_results.py` and the mirror tests in
  `BrickyTests/RecoveryBenchmarkWriterTests.swift`.
- Step-number semantics (internal −1-based index vs authored 0-based
  completed count vs `#N` step ids) are documented in
  [EVIDENCE_BUNDLE_FORMAT.md](EVIDENCE_BUNDLE_FORMAT.md) — route any new
  mapping through `RecoveryBenchmarkInputs` / `stepNumber(from:)` rather
  than adding a fourth convention.
