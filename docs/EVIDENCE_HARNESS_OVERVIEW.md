# Evidence harness: architecture and implementation

Status: implemented (ADR 0007). Last revised 2026-08-04.

This document explains how the recovery evidence harness is built and why.
Companion documents:

- [EVIDENCE_BUNDLE_FORMAT.md](EVIDENCE_BUNDLE_FORMAT.md) — the on-disk and
  interchange schemas, field by field.
- [EVIDENCE_REPLAY_AND_AB.md](EVIDENCE_REPLAY_AND_AB.md) — the `bricky-harness`
  CLI, the device→Mac workflow, and A/B methodology.
- [NEXT_STEPS_AND_FOLLOWUP.md](NEXT_STEPS_AND_FOLLOWUP.md) — owed device work
  and the deferred, measured follow-ups.

## Why this exists

VLM step identification quality was bad and — worse — undiagnosable, because
the pipeline destroyed its own evidence at every layer:

- Raw model output was discarded by `try?` decodes in the MLX runtime; a
  malformed generation and a truncated one were indistinguishable, and both
  left nothing behind.
- The composited comparison board — the only artifact showing exactly what
  the model saw — was deleted in a `defer` even on failure.
- Four distinct estimator failure exits collapsed into one reason-less
  `.insufficient` result.
- `GuidedGenerationLoop` threw `incompleteOutput`/`prematureEOS` on abnormal
  termination, destroying the partial text it had already accumulated.
- Recovery work files were deleted at four sites plus a startup orphan sweep;
  nothing persisted unless the user confirmed a step.
- `RecoveryBenchmarkV1` and the `Tools/RecoveryEvaluation/score_results.py`
  scorer existed with **no producer** — the release-gate corpus had zero rows.

The harness makes every inference call fully observable, gives every recorded
session a ground-truth label path, and closes the loop with a Mac CLI that
replays the exact device runtime so failures reproduce and fixes can be
measured instead of guessed.

## Components

```
┌──────────────────────────── iOS app ────────────────────────────┐
│ RecoveryFlowView / StepCheckView                                │
│   └─ HierarchicalRecoveryEstimator ──▶ RecoveryEvidenceRecorder │
│        │ (recorder: optional observer)   │  Evidence/<session>/ │
│        ▼                                 ▼                      │
│ RecoveryBoardComposer          RecoveryBenchmarkWriter          │
│   (thin UIKit wrapper)         EvidenceExporter ──▶ share sheet │
└───────────┬─────────────────────────────────────────┬───────────┘
            │ links against                            │ zip bundle
┌───────────▼──────────── Packages/RecoveryMLX ────────▼──────────┐
│ RecoveryMLX (MLX runtime)      RecoveryEvidenceKit (no MLX dep) │
│   MLXRecoveryRuntime             EvidenceSchemas                │
│   MLXInferenceTrace              RecoveryBoardLayoutV1          │
│   (rank/check + trace envelope)  EvidenceBundleReader           │
│                                                                 │
│ bricky-harness (macOS executable: replay / recompose)           │
└─────────────────────────────────────────────────────────────────┘
```

### 1. Runtime trace envelope (`Sources/RecoveryMLX`)

`MLXRecoveryRuntime` is the single inference chokepoint for both the app and
the CLI. Instead of throwing typed errors that destroy context, the primary
entry points return an **envelope**:

- `rankWithTrace(imageURL:prompt:candidateCount:modelDirectory:maxTokens:)`
  → `MLXRankResponse`
- `checkStepWithTrace(imageURL:prompt:modelDirectory:)` → `MLXCheckResponse`

Each response carries `output` (nil when the emitted text failed to decode
against the schema) plus an `MLXGenerationTrace`: raw output, decode error
description, generated token count, termination
(`accepted` / `max_tokens_exhausted` / `premature_eos`), latency, the token
budget, and the exact grammar schema JSON used. The legacy `rank`/`checkStep`
methods remain as throwing wrappers so `RecoveryModelManager` and admission
were untouched.

Inside the private `generate()`, `GuidedGenerationError.incompleteOutput` and
`.prematureEOS` are caught and the accumulated partial text is preserved with
the corresponding termination marker — before this, truncation was
unobservable.

Two measured-safe fixes ride along in the same file:

- **Dynamic rank grammar.** `rankSchema(slotCount:)` generates the enum of
  slot letters and `maxItems` per candidate count (clamped 1...8). A fixed
  A–H enum let a 3-tile board legally answer "H", which the estimator then
  dropped without a trace. All eight variants are compiled once at grammar
  warm-up into an immutable array (`GrammarCache.rankConstraints`); each call
  still clones its matcher because matchers are stateful.
- **Rank token headroom.** `rankMaxTokens` is 192 (was 96).
  `GuidedGenerationLoop` reserves 64 tokens for its closing bias, and the
  worst-case 8-slot ranking JSON is ~64 tokens under grammar masking — the
  old budget applied the closing bias from token 32, mid-array. Generation
  still halts at grammar acceptance, so the common case pays nothing.
  `checkMaxTokens` stays 48 deliberately (an A/B candidate, see follow-ups).

### 2. RecoveryEvidenceKit (`Sources/RecoveryEvidenceKit`)

A second library target in the same package with **no MLX dependency** —
Foundation, CoreGraphics, ImageIO, CoreText only — so schema validation and
board composition are testable on any Mac without weights. It is the single
definition of the interchange contract, shared by the app (which re-exports
it via `@_exported import` in `Bricky/Domain/RecoveryEvidence.swift`) and the
CLI:

- `EvidenceSchemas.swift` — every interchange type with explicit snake_case
  `CodingKeys` (see the format doc for why the Foundation
  `convertFromSnakeCase` strategy is banned here), plus `RecoveryCertainty`
  and `RecoveryBenchmarkV1`, which **moved here from the app domain** so the
  scorer contract has exactly one Swift definition. `DeviceIdentity`
  (utsname) and `ProcessFootprint` (`task_vm_info.phys_footprint` — the
  number jetsam actually judges, unlike MLX allocator stats) live here too.
- `RecoveryBoardLayoutV1.swift` — the single authoritative 1024×1024
  comparison-board composer. Pure CGContext + CoreText so it renders
  byte-comparable boards on iOS and macOS. This replaced a UIKit
  `UIGraphicsImageRenderer` composer that silently rendered at *screen
  scale* — on-device boards were 2–3× larger on disk than documented (the
  model still saw 1024 because inference resizes its input). The app's
  `RecoveryBoardComposer` is now a thin UIImage→CGImage wrapper over this.
  `Tools/RecoveryEvaluation/make_board.py` is deprecated as a layout
  authority.
- `EvidenceBundleReader.swift` — reads an unzipped bundle, loads sessions and
  trace rows, and `validate()` returns human-readable structural issues
  (version stamps, decodability, existence of every referenced board, tile,
  and capture image).

### 3. On-device recording (`Bricky/Services/Recovery`)

`RecoveryEvidenceRecorder` is an actor created **per recovery attempt** (and
per step check) only when the developer toggle is on; the estimator takes it
as an optional observer (`recorder: RecoveryEvidenceRecorder? = nil`), so the
disabled path costs nothing and recording can never change an estimate.

Design rules the recorder enforces:

- **Copies, not moves.** Sessions copy captures, boards, and per-candidate
  tile renders into `Evidence/<session-uuid>/`. The recorder never takes
  ownership of recovery work files, so the four existing deletion sites and
  the startup orphan sweep stay byte-for-byte untouched
  (`RecoveryWorkFileCleanup.sweepOrphanedWorkFiles` never visits
  `Evidence/`). `recordPass` runs *before* the caller's `defer` deletes the
  board, capturing the exact image the model saw.
- **Best-effort by design.** Recording must never break a recovery: every
  write path logs and swallows its errors (`perform(_:_:)` with an OSLog
  category of `Evidence`).
- **Bounded.** `purgeIfNeeded` runs before a new session directory is
  created: 40 sessions / 2 GB caps, oldest-first, with 64 MB incoming-session
  headroom.
- **Idempotent finalize.** `finalize(estimate:analysisError:groundTruth:)`
  writes the estimate summary, any analysis error, and the ground-truth
  label exactly once.

`RecoveryBenchmarkWriter` turns a labeled, finalized session into the
session's single `benchmark.ndjson` row — the producer `score_results.py`
never had. `RecoveryBenchmarkInputs.init(plan:expectedCompletedCount:)` is
the one shared step-number mapping (including `plan.stepZeroID → 0`), which
is the off-by-one chokepoint tested against the scorer's example fixture.

### 4. Ground truth, both ways

- **Passive tracing** — every recovery/check with the toggle on is recorded.
  The label arrives when the user taps Confirm (`confirmed`); cancelled,
  failed, and abandoned sessions are kept deliberately as `unlabeled`
  (failures are exactly what needs diagnosing).
- **Corpus collection mode** — a second toggle enables
  `StagedFixtureSetupView`, where the expected step (0 = not started) and
  conditions (lighting, occlusion, physical case, legal-use confirmation)
  are declared **before** capture. The declaration is the label
  (`staged`); the user's eventual Confirm is recorded as a cross-check, not
  the label. Staged sessions produce fully-populated release-corpus
  `RecoveryBenchmarkV1` rows.

### 5. Developer UI and export

`StorageAndAttributionView` gains a Developer section: the two `@AppStorage`
toggles (`developer.evidenceCaptureEnabled`,
`developer.corpusCollectionEnabled` in `AppConfig.Defaults`) and a link to
`EvidenceSessionsView` — session list with ground-truth badges, sizes,
multi-select export, and swipe-delete. `EvidenceExporter` stages hard links
(copy fallback), writes the `evidence_bundle.json` manifest, zips via
ZIPFoundation (already a dependency), and hands the zip to a share sheet.
The zip is the **only** egress; ADR 0007 documents the privacy carve-out and
CONTEXT.md's privacy sentence was amended accordingly ("images never leave
the device *automatically*").

### 6. Mac CLI (`Sources/bricky-harness`)

`bricky-harness` (swift-argument-parser, macOS 14+) replays bundles through
the *same* `MLXRecoveryRuntime`, grammar constraints, and board layout as the
device — the whole point of putting the CLI inside `Packages/RecoveryMLX`.
`replay` emits `RecoveryBenchmarkV1` rows (tagged
`device_model: "replay:<mac>"` so they can never masquerade as device rows)
plus a per-call `<out>.traces.ndjson` sidecar with `matches_device`;
`recompose` rebuilds any trace's board for layout debugging; `--dry-run`
validates a bundle without loading weights (CI-safe). Full reference in
[EVIDENCE_REPLAY_AND_AB.md](EVIDENCE_REPLAY_AND_AB.md).

## Estimator instrumentation

`HierarchicalRecoveryEstimator` (the VLM fallback path since geometric-first
recovery, ADR 0010) labels every inference call with a pass kind —
`broad` → iterative `narrowing` (log-bounded interval shrinking) → `narrow`
→ three `finalist` views (plus `check` from `StepCheckView`) — and each of
its four failure exits now carries a `RecoveryInsufficiencyCause`
(`broad_pass_unmatched`, `narrowing_pass_unmatched`, `final_pass_unmatched`,
`finalist_quorum_not_reached`) on the `RecoveryEstimate`. Certainty stays
cross-view leader agreement (3 → high, 2 → medium) over Borda-scored
finalists.

## Key design decisions

| Decision | Rationale |
| --- | --- |
| Envelope, not errors | Raw output and token counts are needed on success too; the CLI wants traces as return values |
| Runtime toggle in **all** builds, off by default | MLX inference is only representative in Release; `#if DEBUG` gating was rejected (ADR 0007) |
| Copies-only retention | Deletion sites and orphan sweep provably unchanged; evidence can never leak work files |
| On-device format **is** the export format | Dumb files (JPEG + JSON/NDJSON, snake_case) — no SwiftData schema, no migration, Python-readable |
| One board-layout authority in the kit | Kills hand-duplicated constant drift between app, CLI, and `make_board.py`; fixes the screen-scale bug |
| CLI inside the MLX package | Exact device semantics — same runtime actor, same compiled grammars, same input resize |
| Replay rows tagged `replay:` | Mac numbers can never contaminate a device release corpus |

## Tests and CI

- Package tests (macOS, run in CI's `harness-macos` job on every PR):
  `RankSchemaTests` (per-count grammar, clamping) and `EvidenceKitTests`
  (board is exactly 1024², candidate-count bounds, JPEG round-trip, reader
  validation, version rejection, snake_case manifest keys).
- App tests (iOS simulator): recorder round-trip and purge caps, sweep
  leaves `Evidence/` intact, benchmark-writer key set mirrors the scorer's
  `REQUIRED_FIELDS`/`RELEASE_FIELDS`, and step-zero index semantics against
  `fixtures/example-device-results.ndjson`.
- CI never runs inference; `--dry-run` covers bundle structure.
