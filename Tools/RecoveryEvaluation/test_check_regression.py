from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from check_regression import compare, flatten, main, measure
from test_score_results import registration_row, verification_row


def baseline(metrics: dict[str, object]) -> dict[str, object]:
    return {"fixture": "test", "seed": 7, "metrics": metrics}


class FlattenTests(unittest.TestCase):
    def test_nested_reports_become_dotted_paths(self) -> None:
        flat = flatten({"verification": {"per_detectability": {"strong": {"complete_recall": 0.5}}}})
        self.assertEqual(flat, {"verification.per_detectability.strong.complete_recall": 0.5})

    def test_nulls_are_dropped_rather_than_read_as_zero(self) -> None:
        # A metric with no cases is absent, not a perfect (or terrible) score.
        # Coercing it to 0.0 would silently pass a lower_is_better gate.
        self.assertEqual(flatten({"a": None, "b": 1.5}), {"b": 1.5})

    def test_booleans_are_not_treated_as_numbers(self) -> None:
        self.assertEqual(flatten({"failed": True, "rate": 0.25}), {"rate": 0.25})


class CompareTests(unittest.TestCase):
    def test_worse_lower_is_better_metric_is_a_regression(self) -> None:
        regressions, _ = compare(
            {"verification.false_complete_rate": 0.1},
            baseline({"verification.false_complete_rate": {"value": 0.0, "tolerance": 0.0, "direction": "lower_is_better"}}),
        )
        self.assertEqual(len(regressions), 1)
        self.assertIn("false_complete_rate", regressions[0])

    def test_worse_higher_is_better_metric_is_a_regression(self) -> None:
        regressions, _ = compare(
            {"registration.convergence_rate": 0.5},
            baseline({"registration.convergence_rate": {"value": 0.9, "tolerance": 0.05, "direction": "higher_is_better"}}),
        )
        self.assertEqual(len(regressions), 1)

    def test_movement_within_tolerance_is_neither_regression_nor_note(self) -> None:
        regressions, notes = compare(
            {"registration.convergence_rate": 0.88},
            baseline({"registration.convergence_rate": {"value": 0.9, "tolerance": 0.05, "direction": "higher_is_better"}}),
        )
        self.assertEqual(regressions, [])
        self.assertEqual(notes, [])

    def test_improvement_is_reported_but_does_not_fail(self) -> None:
        regressions, notes = compare(
            {"verification.false_complete_rate": 0.0},
            baseline({"verification.false_complete_rate": {"value": 0.2, "tolerance": 0.01, "direction": "lower_is_better"}}),
        )
        self.assertEqual(regressions, [])
        self.assertEqual(len(notes), 1)
        self.assertIn("improved", notes[0])

    def test_a_metric_that_stops_being_measured_is_a_regression(self) -> None:
        # Losing coverage looks like success to any checker that only compares
        # the metrics still present, so absence has to fail loudly.
        regressions, _ = compare(
            {},
            baseline({"verification.false_complete_rate": {"value": 0.0, "tolerance": 0.0, "direction": "lower_is_better"}}),
        )
        self.assertEqual(len(regressions), 1)
        self.assertIn("no longer measured", regressions[0])

    def test_a_null_baseline_entry_records_the_new_value_without_failing(self) -> None:
        regressions, notes = compare(
            {"registration.yaw_rmse_degrees": 1.2},
            baseline({"registration.yaw_rmse_degrees": {"value": None, "tolerance": 0.5, "direction": "lower_is_better"}}),
        )
        self.assertEqual(regressions, [])
        self.assertEqual(len(notes), 1)


class EndToEndTests(unittest.TestCase):
    @staticmethod
    def write(rows: list[dict[str, object]], directory: str, name: str) -> Path:
        path = Path(directory) / name
        path.write_text("\n".join(json.dumps(row) for row in rows) + "\n")
        return path

    def test_clean_run_passes_and_regressed_run_fails(self) -> None:
        clean = [verification_row() for _ in range(8)]
        clean += [verification_row(expected="incomplete", produced="incomplete") for _ in range(4)]
        clean += [registration_row() for _ in range(4)]
        with tempfile.TemporaryDirectory() as directory:
            results = self.write(clean, directory, "clean.ndjson")
            metrics = measure(results)
            baseline_path = Path(directory) / "baseline.json"
            baseline_path.write_text(
                json.dumps(
                    baseline(
                        {
                            "verification.false_complete_rate": {
                                "value": metrics["verification.false_complete_rate"],
                                "tolerance": 0.0,
                                "direction": "lower_is_better",
                            }
                        }
                    )
                )
            )
            self.assertEqual(main([str(results), "--baseline", str(baseline_path)]), 0)

            # One incomplete step now reads as complete: the exact failure the
            # false-complete ceiling exists to prevent.
            regressed = [dict(row) for row in clean]
            for row in regressed:
                if row.get("expected_verdict") == "incomplete":
                    row["produced_verdict"] = "complete"
                    break
            bad = self.write(regressed, directory, "bad.ndjson")
            self.assertEqual(main([str(bad), "--baseline", str(baseline_path)]), 1)

    def test_update_rewrites_the_baseline_in_place(self) -> None:
        rows = [verification_row() for _ in range(6)]
        with tempfile.TemporaryDirectory() as directory:
            results = self.write(rows, directory, "results.ndjson")
            baseline_path = Path(directory) / "baseline.json"
            baseline_path.write_text(
                json.dumps(
                    baseline(
                        {
                            "verification.false_complete_rate": {
                                "value": 0.9,
                                "tolerance": 0.0,
                                "direction": "lower_is_better",
                            }
                        }
                    )
                )
            )
            self.assertEqual(main([str(results), "--baseline", str(baseline_path), "--update"]), 0)
            written = json.loads(baseline_path.read_text())
            self.assertEqual(written["metrics"]["verification.false_complete_rate"]["value"], 0.0)


if __name__ == "__main__":
    unittest.main()
