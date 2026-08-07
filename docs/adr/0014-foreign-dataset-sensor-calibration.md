# ADR 0014: The synthetic sensor model is calibrated from public datasets, not guesses

- Status: Accepted
- Date: 2026-08-07

## Context

`Tools/SyntheticScenes` degrades ideal rendered depth through a `SensorModel`
before handing it to the depth-ICP solver and the geometric verifier, so the
synthetic corpus measures the solver rather than the renderer. Every constant
in that model was invented. CONTEXT.md marks them RECONSTRUCTED and the
`synthetic-gates` CI job runs `continue-on-error` because of it.

The real-parts fixture localised the blocker: a per-view systematic bias of
roughly 15 mm that alternating-view blending cannot cancel, attributed to the
reconstructed edge dilation and dropout. Tuning solver constants against that
would be fitting noise, so the gates stayed informational and the whole
evaluation programme stalled on a device rig that does not exist yet.

Two facts make that stall unnecessary.

**The model's *form* is wrong, not only its constants.** `SensorModel` is
zero-mean Gaussian — `σ(z) = base + range·z²` with no bias term at all — so
there is nowhere for a systematic 15 mm offset to land, and no amount of
refitting the existing parameters can absorb it. Worse, `degrade` zeroes
confidence at depth discontinuities, whereas a real time-of-flight sensor
reports edge pixels as *plausible interpolated depth between foreground and
background at normal confidence*. The synthetic pipeline deletes the very
artifact it is trying to model, so the solver never sees it. This is the
documented flying-pixel artifact (Chugunov et al., *Mask-ToF*, CVPR 2021;
Vasudevan et al., *Color-Guided Flying Pixel Correction*, 2024).

**Public datasets measure exactly this.** ARKitScenes (Apple) publishes 2,257
captures pairing 256×192 ARKit depth with 1920×1440 ground truth projected
from a Faro Focus S70 laser scan — a direct, dense measurement of what ARKit
depth gets wrong. DTTD-Mobile (Huang et al., arXiv:2309.13570) captures
tabletop objects on an iPhone 14 Pro with OptiTrack pose ground truth, deriving
per-pixel truth from CAD plus pose — the same technique `SyntheticRGBD` itself
uses — and independently reports the two things the real-parts fixture found by
hand: high surface distortion at 256×192, and long-tail noise on object
projection edges.

Neither dataset is Bricky's regime. ARKitScenes is room and furniture scale;
DTTD-Mobile is an iPhone 14 Pro at tabletop distance on an older ARKit. Bricky
runs at roughly 0.3–0.6 m against LEGO-scale geometry on iOS 27.

## Decision

Correct the model's form first, then fit it against public data, and never
claim the result is a device measurement.

1. `SensorModel` gains a range-dependent systematic bias term and replaces
   edge dropout with flying-pixel mixing — interpolated foreground/background
   depth carried at ordinary confidence, so the artifact reaches the solver.
   Quantisation is measured rather than assumed.
2. Constants are fitted against ARKitScenes low-res/high-res pairs by
   `Tools/SensorCalibration`, cross-checked at object scale against
   DTTD-Mobile, and committed as data with a written report
   (`docs/SENSOR_CALIBRATION.md`) rather than as literals in Swift.
3. The result is marked **INFERRED**, not VERIFIED, and carries an explicit
   extrapolation argument from furniture scale and iPhone 14 Pro to 0.3 m
   LEGO scale on iOS 27. A device rig replaces it later; until then no
   statement anywhere may describe these constants as measured on a target
   device.
4. CI splits by what each job can honestly assert. `synthetic-regression`
   blocks: it compares fixture metrics against a committed baseline within a
   tolerance band, which needs only determinism, not calibrated truth.
   `synthetic-gates` stays informational: asserting the CONTEXT.md release
   thresholds requires calibrated absolute truth, which INFERRED constants do
   not provide.
5. Anything derived from DTTD-Mobile is validation-only until its licence is
   confirmed; no constant fitted from it is committed before then.

## Consequences

The evaluation programme stops being blocked on hardware. CI can finally fail
a pull request that makes the solver worse — the capability the whole synthetic
harness was built for and has never had, because the one job that existed
conflated regression detection with release certification and therefore could
do neither.

The cost is a standing honesty obligation. These constants describe someone
else's iPhone at the wrong scale, and the residuals in the calibration report
are the only defence against forgetting that. Release certification remains
device-blocked exactly as before; nothing here moves a red gate to green.

The failure this guards against is the one Apple's own evaluation guidance
names: measurements that pass while the system is visibly wrong, because the
defect is in the measurement rather than the system (Evaluations guide 6.1
§10, and §7 on a metric reading 100% over a collapsed distribution). A gate
computed from an invented sensor is that failure with extra steps.
