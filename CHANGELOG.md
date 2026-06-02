# Changelog

All notable changes to Bricky are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

App version reflects `MARKETING_VERSION` in the Xcode project; the build number
is `CURRENT_PROJECT_VERSION`.

## [Unreleased]

### Added

- **Who or What Is This?** — AI subject recognition. Point Bricky at a photo and
  it identifies famous people, cartoon/film characters, landmarks and famous
  places, and musicians using cloud GPT-4o vision. Launches from the Home screen.
  Gated behind Bricky Pro with a fair-use monthly allowance
  (`AppConfig.proMonthlyAIRecognitionLimit`, default 100/month) so the Azure cost
  is covered by the subscription; free users see an honest upsell. The Azure
  OpenAI key never ships in the app — the app calls a server proxy that verifies
  the StoreKit entitlement (signed JWS), enforces the quota, and calls GPT-4o.
  - `Models/RecognizedSubject.swift` — subject, category, and result DTOs.
  - `Services/ImageRecognitionService.swift` — proxy client with honest,
    localized error mapping (offline, not-entitled, quota-exceeded, etc.).
  - `ViewModels/ImageRecognitionViewModel.swift` — idle → recognizing → results /
    empty / failed / upsell state machine.
  - `Views/ImageRecognitionView.swift` + Home entry point.
  - `Views/CameraImagePicker.swift` — shared camera/library picker (extracted from
    Mosaic Studio so both flows reuse it).
  - `SubscriptionManager` monthly AI-recognition quota with calendar-month reset
    and signed-entitlement (`currentEntitlementJWS()`) support.
  - `AppConfig.aiRecognitionEndpoint` configuration (UserDefaults/env override,
    default `https://bricky-recognition.azurewebsites.net/api/recognizeImage`).
- **Bricky recognition proxy** (`services/recognition-proxy`) — Azure Functions v4
  (TypeScript) service that holds the Azure OpenAI key, verifies the StoreKit
  entitlement server-side, enforces a per-user monthly quota in Azure Table
  Storage, and calls GPT-4o vision with a strict "famous subjects only, never
  guess private individuals" system prompt.
- **Mosaic Studio** — turn any photo into a buildable single-layer LEGO mosaic.
  Launches from the Home screen quick-actions (Home → Mosaic Studio). Submits a
  photo to the LEGO Model Generation backend, polls for progress, and returns an
  LDraw model, a step-by-step instructions PDF, a thumbnail, and a complete parts
  list that can be shared. Gated behind Bricky Pro with an honest free-tier upsell.
  - `Models/MosaicJob.swift` — job, progress, result, and parts DTOs.
  - `Services/MosaicGenerationService.swift` — `actor` API client (submit, poll,
    fetch result, download artifacts, resolve relative artifact URLs).
  - `ViewModels/MosaicGeneratorViewModel.swift` — submit → poll → load-result
    state machine with cancellation.
  - `Views/MosaicGeneratorView.swift` — photo picker, size presets, sortable parts
    list, and artifact share sheet.
  - `AppConfig.mosaicApiBaseURL` configuration (UserDefaults key
    `bricky.mosaic.apiBaseURL`, env `BRICKY_MOSAIC_API_URL`, default
    `http://localhost:8000`).
- **LEGO Model Generation backend** (`services/lego-model-gen`) — deterministic
  FastAPI service that converts a 2D photo into a LEGO mosaic (LDraw, instructions
  PDF, parts list, thumbnail, metadata). Validated by golden-file and
  cross-artifact brick-count consistency tests.

### Tests

- `BrickyTests/ImageRecognitionTests.swift` (8 tests) covers the proxy client
  response/error mapping and lenient subject decoding; `ImageRecognitionViewModelTests`
  (3 tests) and `SubscriptionManagerAIQuotaTests` (3 tests) cover the Pro-gating
  state machine and monthly quota accounting. `services/recognition-proxy`
  ships `test/openai.test.ts` and `test/entitlement.test.ts` (15 tests) covering
  GPT-4o response parsing and StoreKit entitlement verification.
- `BrickyTests/MosaicGenerationServiceTests.swift` (9 tests) and
  `BrickyTests/MosaicGeneratorViewModelTests.swift` (6 tests) cover the iOS client
  end to end with a stubbed `URLProtocol`.
- `BrickyUITests` adds `testNavigationToMosaicStudio`, a launch-flow smoke test for
  the new Home entry point.
- Backend golden-file and invariant suite in `services/lego-model-gen`.

### Documentation

- Added `docs/architecture.md`, `docs/features.md`, `CONTRIBUTING.md`, this
  changelog, and a `VERSION` file.

## [1.4.0]

Baseline release at the point changelog tracking began. Established the core
Bricky experience:

- AR and photo-based brick scanning with on-device Vision detection.
- Minifigure identification via a fast color cascade plus CoreML torso/face
  embeddings.
- Inventory management, storage bins, and CSV/XML import.
- Build suggestions driven by available inventory.
- Piece and set catalog browsing.
- Community sharing, daily challenges, scan history with geo-tagging, and LiDAR
  topographic rendering.
- Bricky Pro subscription (StoreKit 2) gating scan limits and premium surfaces.

[Unreleased]: https://github.com/shribr/Bricky/compare/v1.4.0...HEAD
[1.4.0]: https://github.com/shribr/Bricky/releases/tag/v1.4.0
