# Synthetic sensor model: form, calibration, and what is still owed

Companion to [ADR 0014](adr/0014-foreign-dataset-sensor-calibration.md).
Last revised 2026-08-07.

`Tools/SyntheticScenes` degrades ideal rendered depth before handing it to the
depth-ICP solver and the geometric verifier, so the synthetic corpus measures
the solver rather than the renderer. This document is the provenance record for
that degradation: what the model claims, where its numbers come from, and which
of them are still invented.

## Status

| Piece | State |
| --- | --- |
| Fitting tool + tests (`Tools/SensorCalibration`) | ✅ implemented, 14 tests |
| Regression check + committed baseline | ✅ blocking in CI |
| Model form (bias term, flying-pixel mixing) | 🔴 deferred — lands *with* the fit, see below |
| Fitted constants from ARKitScenes | 🔴 **not run** — constants remain RECONSTRUCTED |
| DTTD-Mobile cross-check | 🔴 not run; licence unconfirmed |
| Release gates blocking | 🔴 blocked on the above, deliberately |

**Why the form change waits for the fit.** Adding a bias term and a
flying-pixel term means introducing `b0`, `b1`, and `edge_mix` — three more
invented constants — and every one of them changes what the solver sees. That
would move the regression baseline for reasons no measurement supports,
encoding a guess as the thing future changes are judged against. The form and
its fitted values therefore land together, in one change whose numbers can be
defended. Until then the model keeps its current shape and its current honest
label.

**Nothing in the repository today is calibrated.** The constants in
`SensorModel` are the original invented ones. Any statement that Bricky's
synthetic evaluation is grounded in measurement is false until the "Owed"
section below is closed.

## What was wrong with the model, and why refitting alone could not fix it

The real-parts fixture localised a ~15 mm per-view systematic bias that
alternating-view blending cannot cancel. Two structural problems, not two bad
constants:

1. **No bias term exists.** `SensorModel` is zero-mean Gaussian,
   `σ(z) = base + range·z²`. A systematic offset has nowhere to land, so no
   refit of the existing parameters can absorb one. Published iPhone LiDAR
   surveys report exactly such a range-dependent systematic component.
2. **Edge pixels are deleted rather than modelled.** `degrade` zeroes
   confidence at depth discontinuities. A real time-of-flight pixel spanning
   a depth edge integrates both surfaces and reports a *confident value
   between them* — the flying-pixel artifact. The synthetic pipeline removes
   the very artifact it is trying to reproduce, so the solver never sees it
   and the bias it causes cannot appear in synthetic results at all.

The corrected form:

```
measured(z) = z + bias(z) + N(0, sigma(z)^2), quantised to `quantum`
bias(z)     = b0 + b1 * z
sigma(z)    = s0 + s1 * z^2
edge pixels = foreground + edge_mix * (background - foreground), confidence kept
```

## Sources, and why neither is Bricky's regime

**ARKitScenes** (`apple/ARKitScenes`) — 2,257 captures pairing 256×192 ARKit
depth with 1920×1440 ground truth projected from a Faro Focus S70 laser scan.
The only public source with dense per-pixel truth for this exact sensor
pipeline, which is what makes it the fitting corpus. Room and furniture scale.

**DTTD-Mobile** (Huang et al., [arXiv:2309.13570](https://arxiv.org/abs/2309.13570),
[dataset](https://huggingface.co/datasets/ZixunH/DTTD2-IPhone)) — iPhone 14 Pro
tabletop objects with OptiTrack pose ground truth; per-pixel truth derived from
CAD plus pose, the same technique `SyntheticRGBD` itself uses. Closer to
Bricky's working distance. The paper independently reports the two things the
real-parts fixture found by hand: high surface distortion at 256×192, and
long-tail noise on object projection edges. **Licence unstated** — validation
only, and no constant derived from it may be committed until that is resolved.

Bricky works at roughly **0.3–0.6 m against 8 mm studs and 3.2 mm plates**, on
iOS 27. Neither source is that. Any fit is therefore an extrapolation across
scale, device generation, and ARKit version, and is marked **INFERRED**, never
VERIFIED. `fit_sensor_model.py report` prints per-bin residuals precisely so
that the size of the extrapolation is visible rather than assumed away.

Independent bound on what calibration can buy: Luetzenburg et al.
(*Scientific Reports* 11, 22221, 2021) measure ±1 cm absolute accuracy on
objects with side length above 10 cm and place features below roughly 1 cm
under the sensor's reliable resolution. A plate is 3.2 mm tall. No amount of
sensor-model fidelity makes depth alone a trustworthy judge of a marginal
delta — which is why ADR 0008's RGB support term is owed rather than optional.

## Running the fit

The fitting maths is unit-tested without either download, because corpus
preparation is dataset-specific and deliberately lives outside the module:

```sh
cd Tools/SensorCalibration
python3 -m unittest test_fit_sensor_model.py

# Prepare per-capture JSON on the 256x192 grid (dataset-specific; not in-tree),
# then:
python3 fit_sensor_model.py fit --pairs <prepared> --out sensor_model.json
python3 fit_sensor_model.py check --pairs <dttd-prepared> --model sensor_model.json
```

`fit` refuses to produce constants from a corpus too small or too narrow to
support a depth-dependent model, rather than returning a confident line
through three points.

## Why CI can block anyway

`synthetic-gates` conflated two jobs needing different evidence:

- **Regression detection** — "did this change make the solver worse?" — needs
  only determinism and a committed baseline. No calibrated truth whatsoever.
- **Release certification** — "does the solver meet the CONTEXT.md gates?" —
  needs calibrated absolute truth.

Only the second is blocked on calibration. The first blocks today, against
`fixtures/real-tower/baseline.json` within a tolerance band. Before the split,
a pull request could regress the solver with green CI, because the one job that
existed could do neither honestly.

The deliberately-hard `synthetic-tower` fixture stays characterisation-only and
never gates.

## Owed

As one change, so the form and the numbers justifying it arrive together:

1. Prepare an ARKitScenes corpus (per-capture JSON on the 256×192 grid) and
   run `fit`.
2. Apply the corrected model form to
   `Tools/SyntheticScenes/SyntheticScene.swift`, reading the fitted constants
   from committed JSON rather than Swift literals.
3. Paste the residual table into this document.
4. Regenerate `fixtures/real-tower/baseline.json` (`check_regression.py
   --update`) and explain the movement — it will move, and the explanation is
   the point.
5. Move CONTEXT.md's sensor marker from RECONSTRUCTED to INFERRED with the
   extrapolation argument.

Then separately:

6. Cross-check on DTTD-Mobile, licence permitting.
7. Replace all of it with a device rig, at which point the marker becomes
   VERIFIED and the release-gate scoring step can drop its
   `continue-on-error`.
