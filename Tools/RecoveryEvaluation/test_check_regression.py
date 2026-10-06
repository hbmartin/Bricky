from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from check_regression import auto_guard, compare, flatten, main, measure
from test_score_results import registration_row, verification_row


def summary_row(*, dropped: int = 0, steps: int = 3) -> dict[str, object]:
    return {
        "kind": "synthetic_summary",
        "schema_version": 1,
        "suite": "regression",
        "fixture": "test",
        "seed": 7,
        "steps_sampled": steps,
        "generated_verification_rows": 10,
        "generated_registration_rows": 4,
        "dropped_expected_complete_below_strong": dropped,
        "dropped_by_detectability": {"marginal": dropped},
    }


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

    def test_exact_counts_regress_in_both_directions(self) -> None:
        spec = {"verification.negatives": {"value": 10.0, "tolerance": 0.0, "direction": "exact"}}
        for actual in (9.0, 11.0):
            regressions, _ = compare({"verification.negatives": actual}, baseline(spec))
            self.assertEqual(len(regressions), 1, actual)
            self.assertIn("exact", regressions[0])
        self.assertEqual(compare({"verification.negatives": 10.0}, baseline(spec)), ([], []))

    def test_unknown_direction_is_rejected(self) -> None:
        with self.assertRaisesRegex(SystemExit, "unknown direction"):
            compare({"a": 1.0}, baseline({"a": {"value": 1.0, "tolerance": 0.0, "direction": "sideways"}}))

    def test_more_dropped_rows_is_a_regression(self) -> None:
        # A verifier change that downgrades detectability deletes its own
        # recall failures; the drop count is what exposes it.
        metric = "synthetic_summary.regression.dropped_expected_complete_below_strong"
        regressions, _ = compare(
            {metric: 3.0}, baseline({metric: {"value": 2.0, "tolerance": 0.0, "direction": "lower_is_better"}})
        )
        self.assertEqual(len(regressions), 1)

    def test_a_null_baseline_entry_records_the_new_value_without_failing(self) -> None:
        regressions, notes = compare(
            {"registration.yaw_rmse_degrees": 1.2},
            baseline({"registration.yaw_rmse_degrees": {"value": None, "tolerance": 0.5, "direction": "lower_is_better"}}),
        )
        self.assertEqual(regressions, [])
        self.assertEqual(len(notes), 1)


class AutoGuardTests(unittest.TestCase):
    def test_counts_are_exact_and_failures_and_drops_lower_is_better(self) -> None:
        for metric in ("verification.cases", "verification.negatives", "verification.undetectable_cases",
                       "synthetic_summary.regression.steps_sampled",
                       "synthetic_summary.regression.generated_verification_rows",
                       "repair_plan.cross_step_cases", "synthetic_summary.repair.generated_cross_step_rows"):
            self.assertEqual(auto_guard(metric)["direction"], "exact", metric)
        for metric in ("verification.false_complete_cases", "verification.undetectable_false_completes",
                       "challenge.expected_failure_false_complete_cases", "placement.false_present_cases",
                       "synthetic_summary.regression.dropped_expected_complete_below_strong",
                       "repair_plan.cross_step_harmful_actions"):
            self.assertEqual(auto_guard(metric)["direction"], "lower_is_better", metric)

    def test_rates_and_latencies_are_never_auto_guarded(self) -> None:
        for metric in ("verification.false_complete_rate", "verification.median_latency_ms",
                       "registration.translation_rmse_m", "verification.false_complete_upper_95"):
            self.assertIsNone(auto_guard(metric), metric)


class PlacementMeasureTests(unittest.TestCase):
    def test_measure_includes_placement(self) -> None:
        rows = [
            {"kind": "placement", "schema_version": 1, "fixture_id": "a", "expected_state": "absent",
             "produced_state": "absent"},
            {"kind": "placement", "schema_version": 1, "fixture_id": "b", "expected_state": "present",
             "produced_state": "present"},
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "rows.ndjson"
            path.write_text("\n".join(json.dumps(row) for row in rows) + "\n")
            metrics = measure(path)
        self.assertEqual(metrics["placement.cases"], 2.0)
        self.assertEqual(metrics["placement.negatives"], 1.0)
        self.assertEqual(metrics["placement.false_present_cases"], 0.0)


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

    def test_an_all_complete_corpus_does_not_measure_false_complete(self) -> None:
        # With no negatives the false-complete rate is unmeasured, and flatten
        # drops it, so a baseline that guards it reports "no longer measured"
        # instead of accepting a vacuous 0.0.
        with tempfile.TemporaryDirectory() as directory:
            results = self.write([verification_row() for _ in range(6)], directory, "results.ndjson")
            self.assertNotIn("verification.false_complete_rate", measure(results))

    def test_update_rewrites_the_baseline_in_place(self) -> None:
        rows = [verification_row() for _ in range(6)]
        rows += [verification_row(expected="incomplete", produced="incomplete") for _ in range(4)]
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
            # Count metrics join the baseline automatically.
            self.assertEqual(written["metrics"]["verification.negatives"], {"direction": "exact", "tolerance": 0.0, "value": 4.0})
            self.assertEqual(written["metrics"]["verification.cases"]["value"], 10.0)

    def test_update_refuses_to_null_out_a_vanished_metric(self) -> None:
        # Writing null would retire the guard silently: a null baseline only
        # produces a note on the next run.
        with tempfile.TemporaryDirectory() as directory:
            results = self.write([verification_row() for _ in range(6)], directory, "results.ndjson")
            baseline_path = Path(directory) / "baseline.json"
            original = baseline({
                "verification.false_complete_rate": {"value": 0.0, "tolerance": 0.0, "direction": "lower_is_better"},
            })
            baseline_path.write_text(json.dumps(original))
            self.assertEqual(main([str(results), "--baseline", str(baseline_path), "--update"]), 2)
            self.assertEqual(json.loads(baseline_path.read_text()), original)

            self.assertEqual(
                main([str(results), "--baseline", str(baseline_path), "--update",
                      "--drop", "verification.false_complete_rate"]),
                0,
            )
            self.assertNotIn("verification.false_complete_rate", json.loads(baseline_path.read_text())["metrics"])

    def test_measure_reads_the_generation_summary_by_suite(self) -> None:
        rows = [verification_row(), summary_row(dropped=2)]
        with tempfile.TemporaryDirectory() as directory:
            metrics = measure(self.write(rows, directory, "results.ndjson"))
        self.assertEqual(metrics["synthetic_summary.regression.dropped_expected_complete_below_strong"], 2.0)
        self.assertEqual(metrics["synthetic_summary.regression.dropped_by_detectability.marginal"], 2.0)
        self.assertEqual(metrics["synthetic_summary.regression.steps_sampled"], 3.0)
        self.assertNotIn("synthetic_summary.regression.seed", metrics)


if __name__ == "__main__":
    unittest.main()
