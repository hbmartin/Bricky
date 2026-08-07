"""Fit Bricky's synthetic LiDAR sensor model against real depth measurements.

`Tools/SyntheticScenes` degrades ideal rendered depth before handing it to the
solver, so the synthetic corpus measures the solver rather than the renderer.
Every constant in that degradation was invented (ADR 0014). This tool replaces
them with numbers fitted to published measurements.

The model being fitted, per pixel:

    measured(z) = z + bias(z) + N(0, sigma(z)^2), quantised to `quantum`
    bias(z)     = b0 + b1 * z
    sigma(z)    = s0 + s1 * z^2

plus an edge term. Near a depth discontinuity a time-of-flight pixel integrates
both surfaces and reports a confident value *between* them — the flying-pixel
artifact — rather than dropping out. `edge_mix` is the fraction of the
foreground-to-background span such a pixel lands at, and `edge_radius` how many
pixels from the discontinuity are affected.

Sources, in order of preference:

- **ARKitScenes** (`apple/ARKitScenes`): 256x192 ARKit depth paired with
  1920x1440 ground truth projected from a Faro Focus S70 laser scan. The only
  public source with dense per-pixel truth for this exact sensor pipeline.
- **DTTD-Mobile** (arXiv:2309.13570): iPhone 14 Pro tabletop objects with
  OptiTrack pose ground truth, truth-by-CAD-plus-pose. Closer to Bricky's
  working distance; used to validate a fit, not to produce one, and only if
  its licence permits (see docs/SENSOR_CALIBRATION.md).

Neither is Bricky's regime (~0.3-0.6 m, LEGO-scale geometry, iOS 27), so the
output is INFERRED, never VERIFIED. `report()` prints the residuals that are
the only honest defence of that extrapolation.

Usage:

    uv run python fit_sensor_model.py fit  --pairs <dir> --out sensor_model.json
    uv run python fit_sensor_model.py check --pairs <dir> --model sensor_model.json
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from dataclasses import asdict, dataclass
from pathlib import Path

# Depth bins (meters) the bias and noise curves are fitted over. Bricky works
# at the near end; the wide range exists because the fitting corpus does not.
BIN_EDGES = [0.2, 0.4, 0.6, 0.9, 1.3, 1.8, 2.5, 3.5, 5.0]
# A bin with fewer samples than this is dropped rather than fitted through.
MIN_BIN_SAMPLES = 200
# Truth steps larger than this across neighbouring pixels are a depth
# discontinuity, and pixels near one are excluded from the bias and noise fit
# so the edge term does not contaminate the surface term.
DISCONTINUITY_METERS = 0.02


@dataclass
class SensorModelFit:
    """Fitted constants, in the units `SensorModel` consumes (meters)."""

    bias_offset: float
    bias_per_meter: float
    noise_offset: float
    noise_per_meter_squared: float
    quantum: float
    edge_mix: float
    edge_radius: int
    # Provenance travels with the numbers so no consumer can mistake them for
    # a device measurement.
    source: str
    evidence: str = "INFERRED"
    sample_count: int = 0

    def bias(self, depth: float) -> float:
        return self.bias_offset + self.bias_per_meter * depth

    def sigma(self, depth: float) -> float:
        return self.noise_offset + self.noise_per_meter_squared * depth * depth


def least_squares_line(xs: list[float], ys: list[float]) -> tuple[float, float]:
    """Ordinary least squares for y = a + b*x. Returns (a, b)."""
    n = len(xs)
    if n == 0:
        return 0.0, 0.0
    if n == 1:
        return ys[0], 0.0
    mean_x = sum(xs) / n
    mean_y = sum(ys) / n
    denominator = sum((x - mean_x) ** 2 for x in xs)
    if denominator == 0:
        return mean_y, 0.0
    slope = sum((x - mean_x) * (y - mean_y) for x, y in zip(xs, ys)) / denominator
    return mean_y - slope * mean_x, slope


@dataclass
class Sample:
    """One paired observation: what the sensor said, and what was there."""

    measured: float
    truth: float
    near_edge: bool = False
    # For an edge pixel: the foreground and background depths it sits between,
    # used to fit how far across that span the sensor lands.
    foreground: float | None = None
    background: float | None = None


def binned_statistics(samples: list[Sample]) -> list[tuple[float, float, float, int]]:
    """Per depth bin: (centre, mean residual, residual stddev, count).

    The residual is measured minus truth, so its mean is the systematic bias
    the current model has no term for and its spread is the noise.
    """
    statistics: list[tuple[float, float, float, int]] = []
    for low, high in zip(BIN_EDGES, BIN_EDGES[1:]):
        residuals = [
            sample.measured - sample.truth
            for sample in samples
            if not sample.near_edge and low <= sample.truth < high
        ]
        if len(residuals) < MIN_BIN_SAMPLES:
            continue
        count = len(residuals)
        mean = sum(residuals) / count
        variance = sum((residual - mean) ** 2 for residual in residuals) / count
        statistics.append(((low + high) / 2, mean, math.sqrt(variance), count))
    return statistics


def fit_edge_mix(samples: list[Sample]) -> float:
    """Where between foreground and background an edge pixel lands, 0..1.

    0 means edge pixels read the foreground (no flying pixels); 1 means they
    read the background. The synthetic model previously assumed such pixels
    drop out entirely, which is neither of these.
    """
    fractions: list[float] = []
    for sample in samples:
        if not sample.near_edge or sample.foreground is None or sample.background is None:
            continue
        span = sample.background - sample.foreground
        if abs(span) < DISCONTINUITY_METERS:
            continue
        fractions.append(max(0.0, min(1.0, (sample.measured - sample.foreground) / span)))
    if not fractions:
        return 0.0
    return sum(fractions) / len(fractions)


def fit(samples: list[Sample], *, source: str, quantum: float = 0.001) -> SensorModelFit:
    statistics = binned_statistics(samples)
    if not statistics:
        raise SystemExit(
            f"no depth bin reached {MIN_BIN_SAMPLES} samples; the corpus is too small "
            "or too narrow to fit a depth-dependent model"
        )
    centres = [centre for centre, _, _, _ in statistics]
    means = [mean for _, mean, _, _ in statistics]
    sigmas = [sigma for _, _, sigma, _ in statistics]

    bias_offset, bias_per_meter = least_squares_line(centres, means)
    # sigma is modelled in z^2, so regress against the square.
    noise_offset, noise_per_square = least_squares_line([c * c for c in centres], sigmas)
    return SensorModelFit(
        bias_offset=bias_offset,
        bias_per_meter=bias_per_meter,
        noise_offset=noise_offset,
        noise_per_meter_squared=noise_per_square,
        quantum=quantum,
        edge_mix=fit_edge_mix(samples),
        edge_radius=1,
        source=source,
        sample_count=len(samples),
    )


def report(model: SensorModelFit, samples: list[Sample]) -> str:
    """Per-bin residual after applying the fit — the extrapolation defence."""
    lines = [
        f"source: {model.source}   evidence: {model.evidence}   samples: {model.sample_count}",
        "",
        f"{'bin (m)':>10}  {'n':>8}  {'bias mm':>9}  {'resid mm':>9}  {'sigma mm':>9}",
    ]
    for centre, mean, sigma, count in binned_statistics(samples):
        residual = mean - model.bias(centre)
        lines.append(
            f"{centre:>10.2f}  {count:>8}  {mean * 1000:>9.2f}  "
            f"{residual * 1000:>9.2f}  {sigma * 1000:>9.2f}"
        )
    lines += [
        "",
        f"edge_mix: {model.edge_mix:.3f} "
        "(0 = edge pixels read foreground, 1 = background)",
        "",
        "Bricky works at roughly 0.3-0.6 m against 8 mm studs and 3.2 mm plates.",
        "Bins far from that range are extrapolation, not evidence.",
    ]
    return "\n".join(lines)


def load_pairs(directory: Path) -> list[Sample]:
    """Load paired measured/truth depth samples from a prepared corpus.

    Expects one JSON file per capture: {"measured": [...], "truth": [...],
    "near_edge": [...], "foreground": [...], "background": [...]} already
    projected onto the 256x192 grid. Preparing that corpus from raw
    ARKitScenes or DTTD-Mobile is a separate, dataset-specific step -- keeping
    it out of this module is what lets the fitting maths be unit-tested
    without either download.
    """
    samples: list[Sample] = []
    files = sorted(directory.glob("*.json"))
    if not files:
        raise SystemExit(f"no prepared capture JSON found in {directory}")
    for path in files:
        payload = json.loads(path.read_text())
        measured = payload["measured"]
        truth = payload["truth"]
        near_edge = payload.get("near_edge", [False] * len(measured))
        foreground = payload.get("foreground", [None] * len(measured))
        background = payload.get("background", [None] * len(measured))
        if not len(measured) == len(truth) == len(near_edge):
            raise SystemExit(f"{path.name}: measured/truth/near_edge lengths disagree")
        for index, value in enumerate(measured):
            if value is None or truth[index] is None or truth[index] <= 0:
                continue
            samples.append(
                Sample(
                    measured=float(value),
                    truth=float(truth[index]),
                    near_edge=bool(near_edge[index]),
                    foreground=foreground[index],
                    background=background[index],
                )
            )
    return samples


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    subparsers = parser.add_subparsers(dest="command", required=True)

    fit_parser = subparsers.add_parser("fit", help="fit constants from a prepared corpus")
    fit_parser.add_argument("--pairs", type=Path, required=True)
    fit_parser.add_argument("--out", type=Path, required=True)
    fit_parser.add_argument("--source", default="ARKitScenes")

    check_parser = subparsers.add_parser("check", help="score an existing fit on a corpus")
    check_parser.add_argument("--pairs", type=Path, required=True)
    check_parser.add_argument("--model", type=Path, required=True)

    arguments = parser.parse_args(argv)
    samples = load_pairs(arguments.pairs)

    if arguments.command == "fit":
        model = fit(samples, source=arguments.source)
        arguments.out.write_text(json.dumps(asdict(model), indent=2, sort_keys=True) + "\n")
        print(report(model, samples))
        return 0

    model = SensorModelFit(**json.loads(arguments.model.read_text()))
    print(report(model, samples))
    return 0


if __name__ == "__main__":
    sys.exit(main())
