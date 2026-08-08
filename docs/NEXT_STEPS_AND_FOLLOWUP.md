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

## 2a. The RGB support term (owed, ADR 0008)

`GeometricStepVerifier` refuses a `complete` verdict under marginal
detectability because ADR 0008 requires depth **and RGB** agreement there and
the RGB half was never built. Measured on the real-tower fixture: 6 marginal
cases, complete-recall 0.0 — the gate fails every run and only
`continue-on-error` hides it. Marginal+complete fixtures are out of corpus
scope until this lands (ADR 0008 amendment).

What it needs, in order:

1. A colour plane on `RegistrationFrameInput` — the relay copies depth,
   confidence, intrinsics and pose only, no image.
2. An expected-colour render pass; `ExpectedDepthRenderer` emits depth only,
   its colour attachment being an R32Float depth carrier.
   `ModelSurfaceSample.colorCodes` already exists for this and is read by
   nobody.
3. The verifier agreement term itself.
4. A synthetic **colour** sensor model — which is why this waits for depth
   calibration (ADR 0014) rather than racing it. Building the term against an
   invented colour model would repeat the mistake being corrected.

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

- ✅ **Record geometric recovery attempts.** Done 2026-08-07 as a sibling
  record type (`fits.ndjson`, one `GeometricFitRecord` per scored candidate)
  rather than by widening `RecoveryPassKind`, so "Evidence Trace" keeps
  meaning one VLM inference call. Additive optional file; no version bump.
  Sessions also retain the recovery depth frame (ADR 0007 amendment), which
  is what makes a future geometric replay possible without re-collecting the
  physical corpus.
- **Geometric replay on Mac.** Now unblocked by the retained depth frames,
  but blocked on a refactor: `GeometricRecoveryEstimator` calls
  `HierarchicalRecoveryEstimator.evenlySampledIndices` / `.stepID`, and that
  file imports `RecoveryMLX` and `UIKit`, so the geometric stack cannot
  compile into a macOS tool. `Tools/SyntheticScenes/SyntheticRGBDMain.swift`
  already hand-duplicates `HierarchicalIndices.evenly` because of it — the
  same constant drift the board-layout kit was created to kill. Extract both
  helpers into a UIKit-free home first.
- **Check-trace replay.** `bricky-harness replay` skips `check` traces
  entirely; a `--checks` mode replaying them against `checkStepWithTrace`
  would unlock the check-token-budget A/B in §2.
- **Bundle validation depth.** `EvidenceBundleReader.validate` verifies file
  existence, not image decodability — a corrupt JPEG passes `--dry-run` and
  fails mid-replay. Consider an opt-in `--verify-images` pass. (Depth planes
  are now checked by *size* against their declared `width * height`, because
  a truncated blob reshapes into silently wrong geometry rather than
  failing; images still need the equivalent.)
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

Then: Apple's Foundation Models adapter *training toolkit* ended at 26.0.0 —
its final release — and adapters it produces are incompatible with the OS 27+
base models (runtime custom-adapter loading and its entitlement remain
documented; it is the toolkit that cannot target the current base model). With
no supported way to train an adapter for OS 27, the path is **mlx-vlm
(Python) LoRA** on the pinned Qwen3-VL revision. The
bundle format was designed for this: per-candidate tile renders, exact
boards, prompts, and grammar schemas are all present, so training pairs
(board image + prompt → correct slot ranking) can be generated from bundles
without re-rendering. Keep the adapter evaluation on the same
`score_results.py` gates; a fine-tuned model is just another A/B variant to
the harness.

## 6. Format-evolution reminders

- New fields in interchange types: add as optional, snake_case CodingKeys
  spelled out, no version bump. **Exception while the corpus is empty:** this
  rule exists to keep already-collected rows readable, so it does not apply
  when there are none. `estimator_method` was added as *required* on
  2026-08-07 for exactly that reason — an optional field with a silent
  default is what made the geometric latency gate unreachable in the first
  place, and `validate_recovery_rows` names a missing field more usefully
  than a schema-version mismatch would. Once real rows exist, the rule binds
  again.
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
