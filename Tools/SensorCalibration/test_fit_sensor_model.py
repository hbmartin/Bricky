from __future__ import annotations

import json
import random
import tempfile
import unittest
from pathlib import Path

from fit_sensor_model import (
    MIN_BIN_SAMPLES,
    Sample,
    SensorModelFit,
    fit,
    fit_edge_mix,
    least_squares_line,
    load_pairs,
    report,
)


def planted_samples(
    *,
    bias_offset: float,
    bias_per_meter: float,
    noise_offset: float,
    noise_per_square: float,
    seed: int = 7,
    per_bin: int = MIN_BIN_SAMPLES * 4,
) -> list[Sample]:
    """Samples drawn from a known model, so a fit can be scored against truth."""
    rng = random.Random(seed)
    samples: list[Sample] = []
    for truth in (0.3, 0.5, 0.75, 1.1, 1.55, 2.15, 3.0, 4.25):
        bias = bias_offset + bias_per_meter * truth
        sigma = noise_offset + noise_per_square * truth * truth
        for _ in range(per_bin):
            samples.append(Sample(measured=truth + bias + rng.gauss(0, sigma), truth=truth))
    return samples


class LeastSquaresTests(unittest.TestCase):
    def test_recovers_a_known_line(self) -> None:
        xs = [0.0, 1.0, 2.0, 3.0]
        intercept, slope = least_squares_line(xs, [1.0 + 2.0 * x for x in xs])
        self.assertAlmostEqual(intercept, 1.0, places=9)
        self.assertAlmostEqual(slope, 2.0, places=9)

    def test_degenerate_inputs_do_not_raise(self) -> None:
        self.assertEqual(least_squares_line([], []), (0.0, 0.0))
        self.assertEqual(least_squares_line([5.0], [3.0]), (3.0, 0.0))
        # All-identical x has no slope to recover; the mean is the honest answer.
        self.assertEqual(least_squares_line([2.0, 2.0], [1.0, 3.0]), (2.0, 0.0))


class FitTests(unittest.TestCase):
    def test_recovers_a_planted_bias(self) -> None:
        # The failure this whole tool exists for: the shipping model is
        # zero-mean, so a systematic offset has nowhere to land. A fit that
        # cannot recover a planted bias would reproduce that bug.
        model = fit(
            planted_samples(
                bias_offset=0.004,
                bias_per_meter=0.006,
                noise_offset=0.002,
                noise_per_square=0.004,
            ),
            source="planted",
        )
        self.assertAlmostEqual(model.bias_offset, 0.004, places=3)
        self.assertAlmostEqual(model.bias_per_meter, 0.006, places=3)

    def test_recovers_a_planted_noise_curve(self) -> None:
        model = fit(
            planted_samples(
                bias_offset=0.0,
                bias_per_meter=0.0,
                noise_offset=0.003,
                noise_per_square=0.008,
            ),
            source="planted",
        )
        self.assertAlmostEqual(model.noise_offset, 0.003, places=2)
        self.assertAlmostEqual(model.noise_per_meter_squared, 0.008, places=2)

    def test_a_zero_bias_corpus_fits_no_bias(self) -> None:
        model = fit(
            planted_samples(
                bias_offset=0.0,
                bias_per_meter=0.0,
                noise_offset=0.002,
                noise_per_square=0.004,
            ),
            source="planted",
        )
        self.assertAlmostEqual(model.bias(0.45), 0.0, places=3)

    def test_edge_samples_do_not_contaminate_the_surface_fit(self) -> None:
        # Flying pixels sit metres from truth. If they reached the bias fit
        # they would dominate it, which is why they are excluded by flag.
        samples = planted_samples(
            bias_offset=0.001,
            bias_per_meter=0.0,
            noise_offset=0.002,
            noise_per_square=0.002,
        )
        samples += [
            Sample(measured=truth + 0.5, truth=truth, near_edge=True, foreground=truth, background=truth + 1.0)
            for truth in (0.3, 0.5, 0.75) * 400
        ]
        model = fit(samples, source="planted")
        self.assertAlmostEqual(model.bias_offset, 0.001, places=2)

    def test_too_small_a_corpus_refuses_rather_than_guesses(self) -> None:
        with self.assertRaisesRegex(SystemExit, "too small"):
            fit([Sample(measured=0.5, truth=0.5)], source="planted")


class EdgeMixTests(unittest.TestCase):
    def test_midpoint_edge_pixels_fit_a_half_mix(self) -> None:
        samples = [
            Sample(measured=1.5, truth=1.0, near_edge=True, foreground=1.0, background=2.0)
            for _ in range(50)
        ]
        self.assertAlmostEqual(fit_edge_mix(samples), 0.5, places=6)

    def test_no_edge_samples_yields_zero_not_a_crash(self) -> None:
        self.assertEqual(fit_edge_mix([Sample(measured=1.0, truth=1.0)]), 0.0)

    def test_mix_is_clamped_to_the_span(self) -> None:
        # A measurement beyond the background cannot mean "more than 100 %
        # background"; clamping keeps the constant physically meaningful.
        samples = [Sample(measured=3.0, truth=1.0, near_edge=True, foreground=1.0, background=2.0)]
        self.assertEqual(fit_edge_mix(samples), 1.0)


class LoadPairsTests(unittest.TestCase):
    def test_round_trips_a_prepared_capture(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "capture.json"
            path.write_text(
                json.dumps(
                    {
                        "measured": [0.51, 0.62, None, 0.70],
                        "truth": [0.50, 0.60, 0.65, 0.0],
                        "near_edge": [False, True, False, False],
                        "foreground": [None, 0.60, None, None],
                        "background": [None, 0.90, None, None],
                    }
                )
            )
            samples = load_pairs(Path(directory))
        # The None measurement and the zero truth are both dropped: a pixel
        # with no return is not evidence of anything.
        self.assertEqual(len(samples), 2)
        self.assertTrue(samples[1].near_edge)

    def test_missing_corpus_is_an_error_not_an_empty_fit(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(SystemExit, "no prepared capture"):
                load_pairs(Path(directory))


class ReportTests(unittest.TestCase):
    def test_report_names_the_evidence_level_and_working_range(self) -> None:
        samples = planted_samples(
            bias_offset=0.002,
            bias_per_meter=0.001,
            noise_offset=0.002,
            noise_per_square=0.003,
        )
        model = fit(samples, source="ARKitScenes")
        text = report(model, samples)
        self.assertIn("INFERRED", text)
        self.assertIn("ARKitScenes", text)
        # The extrapolation warning is the point of the report, not decoration.
        self.assertIn("0.3-0.6 m", text)

    def test_evidence_level_cannot_silently_default_to_verified(self) -> None:
        self.assertEqual(SensorModelFit.__dataclass_fields__["evidence"].default, "INFERRED")


if __name__ == "__main__":
    unittest.main()
