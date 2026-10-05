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

Rates alone can improve by losing coverage: if a change stops a scenario from
producing rows (or makes the generator drop them), a rate computed over the
survivors can get better while measuring less. Row counts are therefore
guarded too — `exact` for how many cases each metric was computed over,
`lower_is_better` for rows the generator dropped — and `--update` adds any
missing count metric automatically.

    python3 check_regression.py results.ndjson --baseline fixtures/baseline.json
    python3 check_regression.py results.ndjson --baseline ... --update
    python3 check_regression.py results.ndjson --baseline ... --update --drop METRIC
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from score_results import (
    CHALLENGE_KIND,
    PLACEMENT_KIND,
    REPAIR_KIND,
    partition,
    score_challenge,
    score_placement,
    score_repair,
    score_registration,
    score_verification,
)

LOWER_IS_BETTER = "lower_is_better"
HIGHER_IS_BETTER = "higher_is_better"
# Any movement beyond tolerance is a regression: for counts, "more" and
# "fewer" both mean the corpus changed shape under the rates.
EXACT = "exact"
DIRECTIONS = {LOWER_IS_BETTER, HIGHER_IS_BETTER, EXACT}

# Failure counts: fewer is an improvement, not a change of corpus shape.
# The expected-failure total belongs here too: when the RGB term fixes the
# colour swap, its false completes fall, and that must read as a win.
FAILURE_COUNT_LEAVES = {
    "false_complete_cases",
    "undetectable_false_completes",
    "expected_failure_false_complete_cases",
    "false_present_cases",
    "undetectable_false_present_cases",
    "harmful_actions",
    "direction_disagreement_cases",
}


def auto_guard(metric: str) -> dict[str, object] | None:
    """The spec `--update` adds for a measured metric the baseline lacks, or
    None for metrics that need a human-chosen direction and tolerance (rates,
    and latencies, which vary by runner and are never auto-guarded)."""
    leaf = metric.rsplit(".", 1)[-1]
    if leaf.startswith("dropped_") or leaf in FAILURE_COUNT_LEAVES:
        return {"direction": LOWER_IS_BETTER, "tolerance": 0.0}
    if (
        leaf in {"cases", "negatives", "steps_sampled"}
        or leaf.endswith("_cases")
        or (leaf.startswith("generated_") and leaf.endswith("_rows"))
    ):
        return {"direction": EXACT, "tolerance": 0.0}
    return None


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
    # Generation summaries are guarded by suite, so a fixture's regression
    # and challenge runs never share keys.
    for summary in kinds["synthetic_summary"]:
        suite = str(summary.get("suite", "default"))
        fields = {key: value for key, value in summary.items() if key not in {"kind", "suite", "schema_version", "seed"}}
        report.setdefault("synthetic_summary", {})[suite] = fields
    # Only the metrics are read, never the gates: a regression fixture is by
    # definition not a release corpus, so its bounds would be meaningless.
    if kinds["verification"]:
        report["verification"], _ = score_verification(kinds["verification"])
    if kinds["registration"]:
        report["registration"], _ = score_registration(kinds["registration"])
    if kinds[CHALLENGE_KIND]:
        report["challenge"] = score_challenge(kinds[CHALLENGE_KIND])
    if kinds[PLACEMENT_KIND]:
        report["placement"], _ = score_placement(kinds[PLACEMENT_KIND])
    if kinds[REPAIR_KIND]:
        report["repair_plan"], _ = score_repair(kinds[REPAIR_KIND])
    return flatten(report)


def compare(measured: dict[str, float], baseline: dict[str, object]) -> tuple[list[str], list[str]]:
    """Returns (regressions, notes). Notes are non-fatal observations."""
    regressions: list[str] = []
    notes: list[str] = []
    for metric, spec in sorted(baseline["metrics"].items()):
        expected = spec["value"]
        tolerance = float(spec["tolerance"])
        direction = spec["direction"]
        if direction not in DIRECTIONS:
            raise SystemExit(f"{metric}: unknown direction {direction!r}")

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
        elif direction == EXACT and abs(actual - expected) > tolerance:
            regressions.append(
                f"{metric}: {actual:.4f} differs from baseline {expected:.4f} (exact, ±{tolerance} tolerated)"
            )
        elif abs(actual - expected) > tolerance:
            notes.append(f"{metric}: {actual:.4f} improved on baseline {expected:.4f}")
    return regressions, notes


def update(baseline: dict[str, object], measured: dict[str, float], path: Path, *, drop: set[str]) -> int:
    """Rewrites baseline values from this run. A guarded metric that is no
    longer measured is refused, not written as null: a null baseline only
    produces a note on the next run, so writing it would silently retire the
    guard. Deleting it takes an explicit --drop."""
    metrics: dict[str, dict[str, object]] = baseline["metrics"]
    unknown_drops = sorted(drop - metrics.keys())
    if unknown_drops:
        print(f"refusing: --drop names metrics not in the baseline: {', '.join(unknown_drops)}")
        return 2
    vanished = sorted(metric for metric in metrics if metric not in measured and metric not in drop)
    if vanished:
        print("refusing to update: these guarded metrics are no longer measured")
        for metric in vanished:
            print(f"  {metric}")
        print("Restore the coverage, or pass --drop METRIC to retire a guard deliberately.")
        return 2
    for metric in drop:
        del metrics[metric]
    for metric, spec in metrics.items():
        spec["value"] = measured[metric]
    added = []
    for metric, value in sorted(measured.items()):
        if metric in metrics:
            continue
        spec = auto_guard(metric)
        if spec is not None:
            metrics[metric] = {**spec, "value": value}
            added.append(metric)
    path.write_text(json.dumps(baseline, indent=2, sort_keys=True) + "\n")
    print(f"updated {path}")
    for metric in added:
        print(f"  guarding new count metric {metric}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("results", type=Path)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument(
        "--update",
        action="store_true",
        help="rewrite the baseline from this run; review the diff before committing",
    )
    parser.add_argument(
        "--drop",
        action="append",
        default=[],
        metavar="METRIC",
        help="with --update, delete a baseline metric this run no longer measures",
    )
    arguments = parser.parse_args(argv)

    measured = measure(arguments.results)
    baseline = json.loads(arguments.baseline.read_text())

    if arguments.drop and not arguments.update:
        parser.error("--drop only makes sense with --update")
    if arguments.update:
        return update(baseline, measured, arguments.baseline, drop=set(arguments.drop))

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
