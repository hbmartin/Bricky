# Evidence harness: next steps and follow-up work

Last revised 2026-10-05. Companion to
[EVIDENCE_HARNESS_OVERVIEW.md](EVIDENCE_HARNESS_OVERVIEW.md). The iOS 27
program that supersedes much of the sequencing below — honest gates first,
then device measurement, then the placement-level build diff — is
[IOS27_ROADMAP.md](IOS27_ROADMAP.md).

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
   analysis. **Retracted 2026-09-25:** that analysis assumed a closing bias
   that began mid-array at token 32, but Bricky never passes a
   `closingBias` to `GuidedGenerationLoop.run`, so no soft zone exists.
   With the pinned shim's `any_whitespace=true`, the only way to exhaust
   the budget is a whitespace run; `WhitespaceTokenBias` is the variant to
   try if telemetry shows it. Confirm on device: `termination` should be
   `accepted` on effectively all rank traces, and `max_tokens_exhausted`
   rows should stay absent.
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
   production-sized warm-up with AR, scene mesh, and the ICP tracker active,
   in a fresh process (launch, start AR, then load the model). Set the floor
   to the worst-case `AdmissionSnapshot.modelPeakCostBytes` + 25%. Discard
   samples where `isPeakMasked` is true: the lifetime peak never resets, so
   an earlier load or spike hides the model's own peak.

## 1a. Phase 1 add-on checklist (iOS 27 Phase 2 features, iPhone 17 Pro class)

Phase 2 built these without a device. Everything here is off, in shadow,
or behind a flag until its row is measured. Record each result in the
evidence bundle or the PR that flips the flag.

1. **Staged photo checks, negatives included.** Run staged sessions with
   photo checks, including steps left short. The `check.ndjson` rows must
   score in release mode (`label_kind` staged, provenance `device`).
2. **Evidence windows** (ADR 0007 amendment 2), with evidence capture on:
   - resident memory grows by about 5.5 MB and no more;
   - relay colour and occluder extraction p95 ≤ 3 ms, with no
     ARFrame-retention warnings;
   - record the segmentation buffer's size and alignment, and the colour
     matrix (709 or 601) the sampler saw;
   - `SyntheticRGBD --replay-bundle` on a Mac matches the device verdict
     on strong windows.
3. **Shadow diff cost.** Read the `VerifierIngest` and `BuildDiffIngest`
   signposts in the sustained thermal bucket. This is also the entry
   evidence for M2.1 (placement IDs, peel pass, instanced draws).
4. **Repair direction** (ADR 0015):
   - portrait and both landscapes;
   - model yawed 0°, 45° and 90°;
   - the straight-down fallback ("toward the top of the screen");
   - no flicker when standing on a sector boundary.
5. **Suggested placement** (developer flag): wrong proposals ≤ 5% on the
   Clopper–Pearson bound; registration never starts before "Use Suggested
   Position"; the teal tint is legible on real tables.
6. **Hands-free** (developer flag, ADR 0016):
   - 0 false advances in 30 minutes of background noise (TV, talk);
   - command recall ≥ 95% in a quiet room;
   - narration never triggers a command (the 600 ms gate holds);
   - it works with Speech Recognition denied in Settings, which resolves
     apple-speech gap G21 on whether `NSSpeechRecognitionUsageDescription`
     is needed;
   - command latency with `.frequentFinalization` on the `phrase` preset;
   - Siri's "Next step in Bricky" refuses when the app is backgrounded or
     the phone is locked, and asks before every advance;
   - turning "Show models in Spotlight" off removes every entry;
   - thermal state and memory hold with AR, speech and the VLM together.
7. **Wording.** The owner reviews the phrasebook and narration on screen
   and in VoiceOver. "About one stud" and the forbidden words stay absent.

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
| Finalist selection | The ±1-neighbor finalist set and center-capture funnel may structurally exclude the true step when the narrow pass is off by more than one | `--all-passes` traces quantify how often the truth was outside the finalist set before any redesign |
| Recompose vs stored boards | JPEG re-encode of tiles through the kit should be visually irrelevant | Same-bundle stored-vs-recomposed replay (doubles as item 1.3) |

A former "check token budget" row was withdrawn on 2026-09-25: its premise
(a 64-token closing-bias soft zone) does not exist, because the bias is never
passed (§1 item 2).

## 2a. The RGB support term (owed, ADR 0008)

The challenge suite (2026-09-25) now measures the blind spots this term
and the placement-level diff are meant to close. On `challenge.ldr` at
seed 7, a colour swap reads complete on 3 of 3 strong steps (the expected
failure). More urgently, **a brick one plate (3.2 mm) too high also reads
complete on 3 of 3 strong steps**: the 6 mm depth tolerance swallows the
offset. That is a false-complete class inside today's product boundary,
and it is guarded in `fixtures/challenge/baseline.json` so a fix reads as
an improvement.

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

- **Release gate (VLM recovery):** device rows from legally usable
  authored models, adjacent-step candidates present, lighting and
  occlusion each with ≥2 distinct labels and ≥2 measured elevation bands,
  scored in release mode. Gates: top-3 ≥ 0.95, top-1 ≥ 0.80, composite
  median ≤ 20 s, each judged on its one-sided 95% bound. Currently:
  **zero rows**.
- **Sample sizes follow from the gates (settled 2026-09-25).** The old
  fixed minimums (150 cases / 10 models here, 40 / 6 in the scorer)
  conflicted and are gone. `score_results.py --explain-minimums` prints the
  zero-miss size of each gate: for example ≥59 rows for top-3 ≥ 0.95, ≥149
  negatives for false-complete ≤ 2%, and ≥5 rows for any median-latency
  gate. A required gate with no rows fails release mode. The authored-model
  **diversity floor is pending an owner decision** (6 or 10); until then
  the scorer constant stays at 6.
- **Triad physical corpus (CONTEXT gap):** staged fixtures across the same
  authored-model floor for the registration and verification gates, sized
  by the same bounds. It is a distinct corpus with its own producer
  (geometric rows carry `estimator_method: geometric`) but the same
  staged-fixture declarations and scorer. Verification and registration
  rows need `provenance: device`, and no device producer emits them yet.
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
- **Geometric replay on Mac.** Unblocked by the retained depth frames and,
  since 2026-09-25, by the refactor it waited on: the index schedule and
  step identities live in the Foundation-only `RecoveryIndexing`, and
  `GeometricRecoveryEstimator` records through a `GeometricFitRecording`
  protocol, so the estimator compiles into the macOS SyntheticRGBD tool
  (its hand-copied `HierarchicalIndices` is gone). What remains is the
  replay entry point itself: reading a bundle's `depth/` planes into
  `RegistrationFrameInput` and emitting geometric benchmark rows.
- ✅ **Check-trace replay.** Done 2026-09-25: `bricky-harness replay
  --checks` writes `vlm_check` rows that the scorer reports (false-complete
  first). Negatives still require staged check sessions.
- ✅ **Staged check sessions and the check-target A/B.** Done 2026-09-25:
  with corpus collection on, Check Step and the AR guide's Photo Check take
  a staged declaration, which labels the check whatever the user taps, so a
  build declared short of the checked step is a negative. Photo Check runs
  at the locked registration; with evidence on, each check also records the
  target it did not use (`alternate_tile_relative_paths`), and `replay
  --checks --check-target registered --recompose` pairs the two targets on
  the same photos.
- ✅ **Device-side `vlm_check` rows.** Done 2026-10-05: finalizing a
  labeled session that ran photo checks writes `check.ndjson`, with one
  `vlm_check` row per check (provenance `device`). Release mode accepts
  these rows only from staged declarations on a floor device. Confirmed
  labels stay informational: a step is confirmed only after the user
  accepted the check, so those labels lean toward complete. Phase 1 has to
  collect them: staged check sessions, including builds declared short of
  the checked step.
- **Cloud assist on a hot device.** When the thermal policy withholds the
  VLM (`thermal_deferred`), the user gets the manual picker only. Offering
  cloud assist there needs an ADR 0011 amendment first: today ADR 0011
  offers cloud assist only after a local check returned uncertain, and
  recovery has no cloud path at all.
- **Background model delivery needs device QA.** Since 2026-09-25 the model
  downloads through a background `URLSession` and is verified in the
  foreground (ADR 0003 amendment). The Simulator cannot exercise real
  background launches. Before release, on a device: background the app for
  10 minutes mid-download; force-quit and relaunch (the transfer should be
  re-attached, not restarted); pause for 2 hours and resume (does the
  signed Hugging Face CDN URL in the resume data expire?); and confirm that
  `RecoveryModels/` is excluded from backup.
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
  place, and `validate_rows` names a missing field more usefully
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
