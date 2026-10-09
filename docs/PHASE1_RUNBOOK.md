# Phase 1 runbook

How to turn a Phase 1 device session into every readout the checklist asks
for. The checklist itself is [NEXT_STEPS_AND_FOLLOWUP.md](NEXT_STEPS_AND_FOLLOWUP.md)
§1 and §1a. This file says how each item is measured and what passes.
Written 2026-10-08.

## Before you start

- **The phone:** an iPhone 17 Pro or Pro Max on iOS 27 (ADR 0012).
- **App settings:** in Storage ▸ Developer, turn on "Record recovery
  evidence" and "Corpus collection mode", plus the toggles each item below
  names. Everything is off by default.
- **The Mac:**
  - the pinned LDraw pack (`ldraw-2026-07`; CI's curl and sha256 are in
    `.github/workflows/instruction-parity.yml`);
  - `bricky-harness` (`swift build --package-path Packages/RecoveryMLX`) and
    `SyntheticRGBD` (`xcodebuild -scheme SyntheticRGBD`);
  - for replays, the pinned Qwen3-VL weights.
- **One folder per authored model.** It must hold exactly the files the app
  imported (`.ldr`/`.dat`/`.mpd`), named exactly as the import stored them
  (lowercase), with no subfolders. SyntheticRGBD identifies a model by
  hashing that folder, and skips every session whose model hash differs.
  `phase1_report.py` prints a `MODEL … no --model-ldr matches` hint when
  none matches.
- **Admission profiling needs a fresh process.** Force-quit the app, launch
  it, start AR, then load the model. The lifetime memory peak never resets,
  so a sample taken after an earlier load is masked (ADR 0003).

## Collect, export, report

1. **Label every staged session.**
   - Declare the true step, conditions, physical case and legal use
     before capture.
   - Give the physical build a label. Press "New Build" after taking it
     apart (ADR 0019).
2. **Export.** Use Evidence Sessions ▸ Select ▸ Export.
   - Above about 500 MB the app asks first, because AirDrop gets slow;
     export fewer sessions at a time.
   - The store keeps at most 40 sessions and 2 GB, so export promptly.
   - A ⚠︎ on a row means the recorder failed a write or skipped windows.
     The `RECORDER` line counts these.
3. **Unzip each bundle into its own empty folder.**
4. **Run the report:**

   ```sh
   python3 -I Tools/RecoveryEvaluation/phase1_report.py bundle-a/ bundle-b/ \
     --work report/ \
     --harness "$(swift build --package-path Packages/RecoveryMLX --show-bin-path)/bricky-harness" \
     --model-dir <weights> --model-revision 2fd8dacbdb8f1e54b8c005f081ec5bf79c56376b \
     --synthetic-rgbd <dd>/Build/Products/Debug/SyntheticRGBD --ldraw-root <pack>/ldraw \
     --model-ldr models/tower/tower.ldr --model-ldr models/house/house.ldr
   ```

   - **Missing tools:** each step whose tools are missing prints as
     `NEXT <step>: <command>` instead of running.
   - **Output:** everything lands in `report/phase1_report.json`.
   - **`--strict`:** exits 1 when a release run failed or was refused, or
     a row file had a malformed line. The report skips such a line and
     names it as a `warning:`.

## What each line means

These lines need no tools; they come from the bundles alone.

| Line | Reads | Passes when |
| --- | --- | --- |
| `RELEASE <kind> …` | Each kind is scored in release mode in its own run, on the rows the preflight accepts. Registration rows are never required; the device makes none. | `PASS`. For `vlm_check` and `shadow_check`, `ACCEPTED` means the rows count. Their gates are informational. |
| `EXCLUDED n <kind>: <reason>` | Rows the preflight refuses, with its reason, e.g. confirmed labels or challenge scenarios. | Nothing to pass. Read it before trusting a `RELEASE` line. |
| `TERMINATION` | How generation ended, for rank passes and for step checks. | Effectively every rank trace is `accepted`, and `max_tokens_exhausted` is absent (§1 item 2). |
| `ADMISSION` | The worst measured model cost, warm-up peak less pre-load footprint, × 1.25. Identical snapshots count once. | A number, not `UNMEASURED`. Set the floor to it (§1 item 4). |
| `SHADOW_ADVISOR <build>` | The Foundation Models advisor's runs, answers, refusals, latency and thermal state, per OS build. | Collect until the scorer reports 0 more negatives needed (§1a item 10). |
| `COLOUR_ENCODING` | The colour matrix the sampler saw. | Record it (§1a item 2). |
| `RELAY_AUX_EXTRACT` | Colour and occluder extraction time on evidence windows. | p95 ≤ 3 ms (§1a item 2). |
| `SEGMENTATION` | Segmentation buffer width × height / bytes per row. | Record it (§1a item 2). |
| `RECORDER` | Write failures and skipped windows. | 0, or a known cause. |
| `COUNTS` | Collection progress for the checklist items without a scorer. | The targets below. |
| `VERTICAL_CONTEST device …` | The build diff's raised-plate contest on staged `plate_offset` windows against `complete` ones. | `SEPARATES` (§1a item 16). |

## Checklist items

| Item | How | Pass rule |
| --- | --- | --- |
| §1.1 First bundle | `STEP replay …` and `REPLAY_MATCHES` (needs the weights) | The pipeline runs end to end; `matches_device` holds on accepted generations |
| §1.2 Termination | `TERMINATION` | As above |
| §1.3 Board parity | `NEXT board-parity …` (two replays and `compare_arms.py`) | No score or ranking moves |
| §1.4 Admission floor | `ADMISSION`, fresh-process protocol | Floor set to the printed value |
| §1a.1 Staged photo checks | `RELEASE vlm_check`, then the informational `VLM_CHECK_FALSE_COMPLETE` | Rows `ACCEPTED`; negatives included |
| §1a.2 Evidence windows | `STEP windows …` (strong split on the tool's line), `RELAY_AUX_EXTRACT`, `SEGMENTATION`, `COLOUR_ENCODING` | Strong windows match; p95 ≤ 3 ms. Resident growth of about 5.5 MB and ARFrame-retention warnings: **manual**, Xcode memory gauge and console |
| §1a.3 Shadow diff cost | **Manual**: `xcrun xctrace record --device <udid> --attach Bricky --instrument os_signpost --time-limit 5m`, then read `VerifierIngest` / `BuildDiffIngest` (category Geometry) in the sustained thermal bucket | Entry evidence for M2.1 |
| §1a.4 Repair direction | **Manual**, by eye | As listed in §1a |
| §1a.5 Suggested placement | **Deferred**: the device records no proposals yet | — |
| §1a.6 Hands-free | **Manual**: 30 minutes of background noise, a quiet-room recall count, Siri and Spotlight checks | As listed in §1a |
| §1a.7 Wording | **Manual**: the owner reads on screen and in VoiceOver | No forbidden words |
| §1a.8 Colour check | `STEP colour shadow\|full …`, then `compare_arms.py --primary verification_correct`; relay p95 with evidence **off** is the `RelayAuxiliary` signpost (manual `xctrace`) | ≥ 40 fixtures; Block only after replays lose no completes |
| §1a.9 Photo check geometry | `COUNTS check_geometry_traces`; the overlay is **manual** | The box frames the step's parts |
| §1a.10 FM shadow check | `RELEASE shadow_check`, `SHADOW_ADVISOR`; Mac arm with `--fm-shadow` (informational) | 149 negatives at zero misses, per OS build |
| §1a.11 Repair wording | `STEP wording-sheet`; rate `report/wording/sheet.csv` blind; `score_wording_ab.py --sheet … --key report/wording/key.csv` | MODEL PREFERRED |
| §1a.12 Lattice aliasing | `STEP lattice-rows`, then the `STUD_KEYPOINTS_ENTRY` line | ≥ 30 closing windows over ≥ 3 sessions (`COUNTS lattice_staged_windows`) |
| §1a.13 Build labels | `COUNTS staged_sessions_with_build_label` | Every staged session |
| §1a.14 Stud labels | `STEP stud-labels …` prints refusal counts; overlay on 50 photos is **manual** | Studs correct by eye |
| §1a.15 LoRA | `COUNTS labelled_sessions` | Nothing until 150 |
| §1a.16 Plate offset | `VERTICAL_CONTEST device …` | ≥ 20 raised `plate_offset` and ≥ 20 `complete` windows over ≥ 3 sessions; `SEPARATES` |
| Geometric recovery | `STEP geometric control\|tiebreak …`, then `NEXT compare-geometric …` | Fits replay (the Mac rasterizer may differ from the phone's); the tie-break flips only on the paired comparison (ADR 0010) |

## Traps

- **Release mode by hand.** Running `score_results.py` in release mode on a
  device file requires registration rows by default, and the device makes
  none. Pass `--require-kinds` with the kinds present. `vlm_check` and
  `shadow_check` are accepted there, presence only. The report does this
  for you.
- **Per-session row files.** Device rows live in
  `sessions/*/{benchmark,check,verification,shadow_check}.ndjson`. The report
  merges them, and counts a session exported in two bundles once.
- **One bundle versus several.** `replay`, `fm-shadow` and SyntheticRGBD
  take one bundle; `lattice-rows` and `wording-sheet` repeat `--bundle`.
- **Mixed revisions in geometric arms.** A tie-break arm records
  `depth-icp-geometric-v1+pcs1` wherever the tie-break fired, so pass
  `compare_arms.py --allow-mixed-revisions`.
- **Release recovery will read `REFUSED` for a while.** That comes from the
  6-model floor, the variety rules, and insufficient VLM rows without slots.
  It is correct output, not a tool failure.
- **Sessions recorded before 2026-10-08** have no recorded alignment and
  cannot replay geometric recovery. The replay counts them as skipped.

## Not covered yet

- an `xctrace` p95 parser for the signposts;
- a record of whether AR was running at warm-up;
- device records for hands-free and suggested placement;
- photo overlays for check boxes and stud labels.
