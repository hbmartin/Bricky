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

## Amendment 2 (2026-10-05): verification evidence windows

The 2026-08-07 amendment said that keeping depth from frames the user never
chose to capture would need a fresh decision. This is that decision, taken
with the iOS 27 roadmap's Phase 2 plan (M2.2).

**What is retained.** While evidence capture is on, the AR guide keeps the
last 8 frames the step verifier judged, about 1.6 s. They are written as a
window when:
- the published verdict changes kind (at least 3 s apart);
- the user confirms the step;
- the step changes while the verdict is not complete (an override);
- the user leaves the step.

Each frame keeps:
- the depth and confidence planes, as for recovery;
- the registration it was judged under;
- the verdict after it;
- two new channels on the 256×192 depth grid: the camera image
  box-filtered to RGB8, and ARKit's person-segmentation mask as 0/1.

Layout: `windows/<window-id>.json`, plus `windows/frames/` for the planes,
which are shared between overlapping windows. A staged verification
declaration made before the step closes adds one `verification` row to
`verification.ndjson` (provenance `device`).

**Why.** Today a verifier verdict on device leaves no trace. Its
false-complete rate and the per-placement build diff (M2.3) can only be
measured on real frames if those frames are kept. The colour plane is the
input the RGB term (ADR 0008) will need. The mask lets a hand in view be
recognised as an occluder later.

**Exposure.**
- The colour plane is a 256×192 image of what the camera saw. It is lower
  resolution than the capture JPEGs a bundle already holds, but it comes
  from frames the user did not choose.
- The mask outlines the user's hands or body.
- Neither channel feeds any verdict yet. The mask stays unused until its
  quality is checked on device (Phase 1).
- Consent and egress are unchanged: the same off-by-default developer toggle
  gates recording, and the manual share-sheet export remains the only way
  anything leaves the device.

**Limits.**
- At most 48 windows per session (about 265 MB).
- No windows when the volume has less than 2 GB free.
- The existing 40-session / 2 GB purge still applies.

**Replay.** `SyntheticRGBD <model> --ldraw-root <pack> --replay-bundle
<bundle> --out <rows>` replays each window through the app's verifier. A
fresh verifier sees only the window's frames, while the device's had been
accumulating since the step began, so disagreement with the device's verdict
is reported, not treated as a defect.

## Amendment 3 (2026-10-06): photo-check pose and delta box

With evidence on, an AR Photo Check now records two more things:

- **The model pose.** The session's capture record gains
  `world_from_model`: the locked registration's model pose at the moment of
  the photo, column-major like `camera_transform`.
- **Where the delta fell.** The check's trace row gains `check_geometry`.
  After inference, the app renders the completed build and the step's
  additions from the photo's own camera under that pose. It records the box
  around the visible delta, normalized to the upright stored photo, and its
  pixel count. Nothing is asked of a model: geometry places the box.

**Why.** The Foundation Models shadow test (Phase 3, ADR 0018) uses the
pattern "locate with geometry, crop, ask a closed question". A Mac replay
cannot locate anything: bundles never carry the instruction model or the
part pack, so the delta cannot be re-rendered off the device. Recording the
box on device is the only way a replay can crop.

**Exposure.** A pose and four numbers per check, describing the user's own
build. No new image is recorded. Consent and egress are unchanged: the same
off-by-default developer toggle gates recording, and the manual share-sheet
export remains the only way anything leaves the device. The Check Step
screen has no registration, so its checks carry neither field.

**The colour plane feeds the colour term (added with C8, 2026-10-06).**
Amendment 2 said neither auxiliary channel feeds any verdict. That changes
for the colour plane only, and only behind a developer setting:
- **The term.** The RGB term (ADR 0008 amendment, Proposed) reads it. Off
  by default; in Shadow it only records, and in Block only it may take a
  `complete` away.
- **When it is extracted.** When the term is on, the relay extracts the
  colour plane even with evidence capture off, so the term can run.
- **Where it goes.** The plane stays in memory for the visit and is written
  nowhere unless evidence capture is also on. It never leaves the device
  except in a manually exported bundle.
- **The mask.** The occluder mask is still recorded only.
- **Cost.** Relay extraction p95 with evidence off is a Phase 1 check
  (`NEXT_STEPS_AND_FOLLOWUP.md` §1a).

## Note (2026-10-07, iOS 27 Phase 4): lattice evidence

Window frames and fit records gain `lattice_runner_up`, the alternative pose
that came closest to the fit. Photo-check captures gain the registration
they were taken under: its state, lattice margin and runner-up. These are a
few numbers from the solver, describing the user's own build; no image,
depth or new channel is recorded. They exist so Phase 1 can measure stud
lattice aliasing, the entry criterion for stud keypoints. Consent and egress
are unchanged.

Sessions may also carry `physical_build_id`, a short label the person
declares for the build they photograph (ADR 0019). It names an object on
their table, not a person or a place, and it is chosen, never derived.
