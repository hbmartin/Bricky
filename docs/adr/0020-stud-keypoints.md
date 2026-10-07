# ADR 0020: Stud keypoints wait for measured lattice aliasing

- Status: Proposed. The measurement, the labels and the seam exist; no
  model is trained and nothing calls one.
- Date: 2026-10-07

## Context

Roadmap §4.1.3 proposes a stud keypoint heatmap on Core AI to resolve the
8 mm stud-lattice aliasing and sharpen "misplaced" verdicts. LDraw's stud
primitives give geometry labels for free, but a synthetic image would
need an invented sensor and invented colour, which ADR 0008 and ADR 0014
forbid. The program plan's entry criterion is "real rows show lattice
aliasing". Before Phase 4, nothing could even test that criterion:
- the tracker kept only the smallest lattice cost ratio;
- the verifier's ±1-stud contests and the build diff's tallies never
  reached evidence;
- the synthetic sweep never asked for ambiguity;
- no scorer read `lattice_margin`.

## Decision (Proposed)

**Measure first.** Phase 4 records:
- which lattice alternative won (`lattice_runner_up`), on window frames,
  fit records and photo captures;
- the verifier's contests (`lattice_contests`) and the diff's tallies.

A synthetic `--suite lattice` gives `registration.ambiguity_recall` cases
whose truth comes from renders. `bricky-harness lattice-rows` turns device
windows into `lattice_window` rows, and `score_results.py` prints
`STUD_KEYPOINTS_ENTRY` on every run.

**Entry.** That readout says MET:
- at least 30 device windows that closed on staged `complete` or
  `shifted_one_stud` builds, from at least 3 sessions;
- and a one-sided 95% lower bound of at least 5% on the rate of lattice
  trouble. A window counts as trouble when any of these holds:
  - the verifier refused for `poseAmbiguous`;
  - at least half its frames were ambiguous;
  - a complete build was called misplaced;
  - a one-stud shift was called complete.

NOT_MET (upper bound under 5%) closes the question until the verifier
changes. UNMEASURED never reads as either.

**Labels.**
- Real staged photo captures only. `SyntheticRGBD --stud-labels-bundle`
  projects the authored top studs of what the staged declaration says was
  built, through the pose the photo was taken under. `StudIndex` keeps
  stud identity through the flatten, and the tag pass renders stud ids
  for visibility.
- Captures whose pose was not locked well clear of a lattice alias
  (margin under 1.5) are refused: such a pose would mislabel every stud
  consistently.
- Labels are checked by eye before training. No synthetic RGB, ever.

**Authority.** Asymmetric, in shadow first. A stud term may block a
`complete` or sharpen a `misplaced` offset the depth contests already
favour. It never completes anything on its own, and never gives the user a
coordinate, an offset or a direction (ADR 0015: geometry measures).

**Runtime.** `StudKeypointDetecting`, with no detector by default, and a
`CoreAIStudKeypointDetector` skeleton under `#if canImport(CoreAI)` that
nothing constructs. The roadmap's Core AI traps bind any model:
- compile ahead of time for h18p, since `coreai-build` exits 0 for any
  architecture;
- specialize on opt-in, never mid-build, because every OS update purges
  the cache;
- at most one run in flight;
- lay inputs out to `preferredStrides`;
- copy the input crop, because zero-copy `CVPixelBuffer` input is
  undemonstrated.

The Simulator SDK and Xcode 16.4 lack Core AI, so CI type-checks the seam
against the iOS 27 device SDK, with a probe that fails if Core AI is
absent.

**Exit (before the term may block in the app).**
- The verification false-complete upper bound stays at or below 2%.
- Recall on staged `shifted_one_stud` builds improves under an exact
  McNemar test.
- `complete` called `misplaced` does not rise, on staged device windows
  replayed with and without the term.
- ARKit contention for the Neural Engine is measured on a 17 Pro.

## Consequences

- Phase 1 sessions must collect staged `complete` and `shifted_one_stud`
  windows, label each physical build, and keep evidence capture on for
  photo checks. The checklist lives in NEXT_STEPS §1a.
- On the reconstructed synthetic sensor, every lattice solve reads
  ambiguous. The synthetic suite guards movement; it says nothing about
  real LiDAR.
- The stud catalog is checked against the pinned pack on every CI run:
  every `p/stu*` primitive classified, and the top-stud counts of five
  common parts pinned.
