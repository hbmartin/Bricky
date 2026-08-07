"""Fail when a change makes the synthetic solver measurably worse.

This is deliberately *not* `score_results.py`. That script asks "does the
solver meet the CONTEXT.md release gates?", which requires calibrated absolute
truth and therefore cannot block while the sensor model is invented
(ADR 0014). This one asks "is the solver worse than it was?", which needs only
a deterministic fixture and a committed baseline — no calibration at all.

Conflating the two is why CI could not block on either: the release gates fail
honestly on a RECONSTRUCTED sensor model, so the whole job runs
`continue-on-error`, so a pull request that regressed the solver went green.

Each guarded metric declares which direction is worse and how much movement is
noise. Tolerances absorb small floating-point differences in the Metal raster
pass across runner GPUs; they are not headroom for "slightly worse is fine".

    python3 check_regression.py results.ndjson --baseline fixtures/baseline.json
    python3 check_regression.py results.ndjson --baseline ... --update
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from score_results import partition, score_registration, score_verification

LOWER_IS_BETTER = "lower_is_better"
HIGHER_IS_BETTER = "higher_is_better"


def flatten(report: dict[str, object], prefix: str = "") -> dict[str, float]:
    """Dotted metric paths to numeric leaves. Nulls are dropped: a metric with
    no cases is absent, not zero, and must not read as a perfect score."""
    flat: dict[str, float] = {}
    for key, value in report.items():
        path = f"{prefix}{key}"
        if isinstance(value, dict):
            flat.update(flatten(value, prefix=f"{path}."))
        elif isinstance(value, bool):
            continue
        elif isinstance(value, (int, float)):
            flat[path] = float(value)
    return flat


def measure(path: Path) -> dict[str, float]:
    rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    if not rows:
        raise SystemExit("no rows to measure")
    kinds = partition(rows)
    report: dict[str, object] = {}
    # allow_small_corpus throughout: a regression fixture is by definition not
    # a release corpus, and the minimum-corpus rule exists to stop small
    # samples masquerading as release evidence.
    if kinds["verification"]:
        report["verification"], _ = score_verification(kinds["verification"], allow_small_corpus=True)
    if kinds["registration"]:
        report["registration"], _ = score_registration(kinds["registration"], allow_small_corpus=True)
    return flatten(report)


def compare(measured: dict[str, float], baseline: dict[str, object]) -> tuple[list[str], list[str]]:
    """Returns (regressions, notes). Notes are non-fatal observations."""
    regressions: list[str] = []
    notes: list[str] = []
    for metric, spec in sorted(baseline["metrics"].items()):
        expected = spec["value"]
        tolerance = float(spec["tolerance"])
        direction = spec["direction"]

        if metric not in measured:
            # The metric vanished — usually the fixture stopped producing that
            # class of case. That silently removes coverage, so it is a
            # regression, not a note.
            regressions.append(f"{metric}: no longer measured (baseline {expected})")
            continue
        actual = measured[metric]
        if expected is None:
            notes.append(f"{metric}: baseline had no value, now {actual:.4f}")
            continue

        expected = float(expected)
        if direction == LOWER_IS_BETTER and actual > expected + tolerance:
            regressions.append(
                f"{metric}: {actual:.4f} worse than baseline {expected:.4f} (+{tolerance} tolerated)"
            )
        elif direction == HIGHER_IS_BETTER and actual < expected - tolerance:
            regressions.append(
                f"{metric}: {actual:.4f} worse than baseline {expected:.4f} (-{tolerance} tolerated)"
            )
        elif abs(actual - expected) > tolerance:
            notes.append(f"{metric}: {actual:.4f} improved on baseline {expected:.4f}")
    return regressions, notes


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("results", type=Path)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument(
        "--update",
        action="store_true",
        help="rewrite the baseline from this run; review the diff before committing",
    )
    arguments = parser.parse_args(argv)

    measured = measure(arguments.results)
    baseline = json.loads(arguments.baseline.read_text())

    if arguments.update:
        for metric, spec in baseline["metrics"].items():
            spec["value"] = measured.get(metric)
        arguments.baseline.write_text(json.dumps(baseline, indent=2, sort_keys=True) + "\n")
        print(f"updated {arguments.baseline}")
        return 0

    regressions, notes = compare(measured, baseline)
    for note in notes:
        print(f"note: {note}")
    if regressions:
        print("\nREGRESSION")
        for regression in regressions:
            print(f"  {regression}")
        print(
            "\nIf the change is intended, re-run with --update and explain the "
            "movement in the commit message."
        )
        return 1
    print(f"no regression against {arguments.baseline.name} ({len(baseline['metrics'])} metrics)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
