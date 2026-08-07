# ADR 0007: Developer evidence capture may export recovery images manually

- Status: Accepted
- Date: 2026-08-03

## Context

Recovery quality was unmeasurable because the pipeline destroyed its own
evidence: the composited inference board was deleted in a `defer` even on
failure, raw model output was discarded by `try?` decodes, four estimator
exits collapsed into a reason-less insufficient result, and nothing persisted
unless the user confirmed a step. The `RecoveryBenchmarkV1` schema and the
`Tools/RecoveryEvaluation` scorer existed with no producer, so the 150-case
release gate in CONTEXT.md had zero rows. CONTEXT.md also promised that
instruction models and images never leave the device, which any Mac-side
debugging workflow must reconcile.

## Decision

Add an off-by-default developer toggle, compiled into all build
configurations, that records full-fidelity recovery evidence into
`Evidence/<session>/` in the app-support namespace: session metadata, one
NDJSON trace row per inference call (prompt, grammar schema, raw model
output, decode error, termination, latency, memory footprint), and private
copies of captures, boards, and per-candidate tiles. Debug-configuration
gating was rejected because MLX inference is only representative in Release
builds. Everything is a copy — the existing deletion sites and the startup
orphan sweep are untouched — and the store is capped (40 sessions / 2 GB,
oldest purged first).

The only egress is explicit: the user selects sessions in the Developer
section and exports a versioned zip bundle through the share sheet. Bundles
are dumb files (JPEG + JSON/NDJSON with snake_case keys) so the Mac harness
and Python tooling read them without Swift. A corpus-collection mode
declares the expected step and capture conditions up front and emits
fully-populated `RecoveryBenchmarkV1` rows; the same corpus is the intended
training input for a future MLX LoRA adaptation pass.

## Consequences

The privacy sentence in CONTEXT.md is amended: images never leave the device
*automatically*; the developer toggle permits explicit, manual export. The
toggle is visible in release builds and documented here rather than hidden.
Evidence adds bounded disk usage that the Storage tab reports and can purge.
Benchmark rows for MLX/AR changes should originate from exported bundles
replayed through `bricky-harness` so device and Mac numbers share one format.

## Amendment 2026-08-07: depth frames join the carve-out

Geometric-first recovery (ADR 0010) fits a LiDAR depth observation, and that
observation is the one bundle input that cannot be reconstructed from anything
else: the captures are JPEGs of the same scene at a different resolution with
no metric depth, and fit records are outputs. A corpus collected without it
could never support a geometric A/B without re-capturing every physical
fixture — precisely the re-collection this format exists to prevent, and the
same "capture it once, correctly" reasoning that governs the training path.

Sessions therefore retain the recovery depth frame: raw little-endian float32
and uint8 planes under `depth/`, plus a JSON sidecar with the intrinsics,
pose, and timestamp needed to reproject them. Roughly 0.5 MB per session
against the existing 40-session / 2 GB caps.

This adds a sensor modality to what an exported bundle can contain, so it is
recorded here rather than assumed. The incremental privacy exposure is nil:
the same bundle already carries a full-resolution JPEG of the identical view,
which is strictly more revealing than a 256×192 depth map of it. Nothing
changes about consent — the same off-by-default toggle gates recording, and
the same manual share-sheet export remains the only egress. What would need a
fresh decision is retaining depth from frames the user never chose to capture,
and that is not what this does.

Geometric candidate fits are likewise recorded, as `fits.ndjson`. They are
derived data rather than a new modality and raise no additional exposure, but
they are named here so the bundle's contents are fully enumerated in one
place.
