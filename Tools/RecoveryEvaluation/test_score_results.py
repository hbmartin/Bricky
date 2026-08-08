from __future__ import annotations

import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path

from score_results import (
    MINIMUM_AUTHORED_MODELS,
    MINIMUM_CORPUS_ROWS,
    REGISTRATION_YAW_RMSE_DEGREES,
    VERIFICATION_UNCERTAIN_ON_CORRECT_CEILING,
    main,
    partition,
    score_recovery,
    score_registration,
    score_verification,
    validate_release_corpus,
    validate_rows,
)


def benchmark_row(
    *,
    certainty: str = "high",
    include_top: bool = True,
    estimator_method: str = "vlm",
    latency: int | float = 12_000,
) -> dict[str, object]:
    row: dict[str, object] = {
        "schema_version": 1,
        "fixture_id": "fixture",
        "instruction_sha256": "0" * 64,
        "pyldraw3_version": "1.5.0",
        "part_pack_version": "2026-07",
        "expected_step_id": "main.ldr#2",
        "candidate_slots": {"A": "main.ldr#2", "B": "main.ldr#1"},
        "board_relative_paths": ["boards/fixture.jpg"],
        "camera_metadata": [{"fx": 1_200.0, "fy": 1_200.0}],
        "expected_step_index": 2,
        "ranked_step_ids": [] if certainty == "insufficient" else ["main.ldr#2"],
        "certainty": certainty,
        "estimator_method": estimator_method,
        "device_model": "iPhone",
        "operating_system": "iOS",
        "latency_ms": latency,
        "memory_peak_bytes": 4_800_000_000,
    }
    if include_top:
        row["top_step_index"] = None if certainty == "insufficient" else 2
    return row


def verification_row(
    *,
    expected: str = "complete",
    produced: str = "complete",
    detectability: str = "strong",
    latency: int | float = 1_500,
) -> dict[str, object]:
    return {
        "kind": "verification",
        "schema_version": 1,
        "fixture_id": "fixture",
        "expected_verdict": expected,
        "produced_verdict": produced,
        "detectability": detectability,
        "latency_ms": latency,
    }


def registration_row(
    *,
    converged: bool = True,
    translation: float = 0.001,
    yaw: float = 0.5,
    ambiguity_expected: bool = False,
    reported_ambiguous: bool = False,
) -> dict[str, object]:
    return {
        "kind": "registration",
        "schema_version": 1,
        "fixture_id": "fixture",
        "converged": converged,
        "translation_error_m": translation,
        "yaw_error_degrees": yaw,
        "ambiguity_expected": ambiguity_expected,
        "reported_ambiguous": reported_ambiguous,
        "latency_ms": 90,
    }


class RowValidationTests(unittest.TestCase):
    def test_insufficient_row_may_omit_top_step_index(self) -> None:
        validate_rows([benchmark_row(certainty="insufficient", include_top=False)])

    def test_sufficient_row_requires_top_step_index(self) -> None:
        with self.assertRaisesRegex(SystemExit, "requires top_step_index"):
            validate_rows([benchmark_row(include_top=False)])

    def test_boolean_is_not_accepted_as_an_integer_index(self) -> None:
        row = benchmark_row()
        row["top_step_index"] = True
        with self.assertRaisesRegex(SystemExit, "integer >= -1"):
            validate_rows([row])


class MeasurementValidationTests(unittest.TestCase):
    # NaN silently poisons every median and comparison it touches instead of
    # failing a gate, and a negative latency is a recording bug, not a fast
    # run; all three row kinds must refuse them.

    def test_recovery_rejects_non_finite_and_negative_latency(self) -> None:
        for latency in (float("nan"), float("inf"), -1):
            with self.assertRaisesRegex(SystemExit, "latency_ms"):
                validate_rows([benchmark_row(latency=latency)])

    def test_verification_rejects_non_finite_and_negative_latency(self) -> None:
        for latency in (float("nan"), float("-inf"), -5):
            with self.assertRaisesRegex(SystemExit, "latency_ms"):
                score_verification(
                    [verification_row(latency=latency)], allow_small_corpus=True
                )

    def test_registration_rejects_non_finite_measurements(self) -> None:
        for field, value in (
            ("translation_error_m", float("nan")),
            ("yaw_error_degrees", float("inf")),
            ("latency_ms", -3),
        ):
            row = registration_row()
            row[field] = value
            with self.assertRaisesRegex(SystemExit, field):
                score_registration([row], allow_small_corpus=True)


class ReleaseCorpusValidationTests(unittest.TestCase):
    @staticmethod
    def release_rows(fixture_id: str | None = None) -> list[dict[str, object]]:
        rows: list[dict[str, object]] = []
        for index in range(MINIMUM_CORPUS_ROWS):
            row = benchmark_row()
            row.update(
                fixture_id=fixture_id or f"fixture-{index}",
                physical_case=True,
                authored_model_id=f"model-{index % MINIMUM_AUTHORED_MODELS}",
                legal_use_confirmed=True,
                lighting_condition="daylight" if index % 2 else "indoor",
                capture_angle="left" if index % 2 else "right",
                occlusion_condition="none" if index % 2 else "partial",
            )
            rows.append(row)
        return rows

    def test_complete_physical_corpus_passes_preflight(self) -> None:
        rows = self.release_rows()
        validate_rows(rows)
        validate_release_corpus(rows)

    def test_duplicated_fixture_ids_fail_preflight(self) -> None:
        with self.assertRaisesRegex(SystemExit, "distinct fixture IDs"):
            validate_release_corpus(self.release_rows(fixture_id="fixture-repeated"))

    def test_release_row_requires_explicit_provenance(self) -> None:
        rows = [benchmark_row() for _ in range(MINIMUM_CORPUS_ROWS)]
        with self.assertRaisesRegex(SystemExit, "missing fields"):
            validate_release_corpus(rows)


class PartitionTests(unittest.TestCase):
    def test_rows_without_kind_default_to_recovery(self) -> None:
        kinds = partition([benchmark_row(), verification_row(), registration_row()])
        self.assertEqual(len(kinds["recovery"]), 1)
        self.assertEqual(len(kinds["verification"]), 1)
        self.assertEqual(len(kinds["registration"]), 1)

    def test_unknown_kind_is_rejected(self) -> None:
        with self.assertRaisesRegex(SystemExit, "unknown kind"):
            partition([{"kind": "telemetry"}])


class VerificationScoringTests(unittest.TestCase):
    def test_clean_results_pass_all_gates(self) -> None:
        rows = (
            [verification_row() for _ in range(40)]
            + [verification_row(expected="incomplete", produced="incomplete") for _ in range(40)]
            + [verification_row(expected="uncertain", produced="uncertain", detectability="undetectable") for _ in range(20)]
        )
        report, failed = score_verification(rows, allow_small_corpus=False)
        self.assertFalse(failed)
        self.assertEqual(report["false_complete_rate"], 0.0)
        self.assertEqual(report["undetectable_abstention_rate"], 1.0)

    def test_false_complete_is_the_headline_gate(self) -> None:
        # 3 wrong "complete" verdicts in 40 negatives is 7.5% — over the 2%
        # ceiling even though everything else is perfect.
        rows = (
            [verification_row() for _ in range(60)]
            + [verification_row(expected="incomplete", produced="incomplete") for _ in range(37)]
            + [verification_row(expected="incomplete", produced="complete") for _ in range(3)]
        )
        report, failed = score_verification(rows, allow_small_corpus=False)
        self.assertTrue(failed)
        self.assertGreater(report["false_complete_rate"], 0.02)

    def test_missing_abstention_on_undetectable_fails(self) -> None:
        rows = (
            [verification_row() for _ in range(20)]
            + [verification_row(expected="uncertain", produced="complete", detectability="undetectable") for _ in range(5)]
        )
        _, failed = score_verification(rows, allow_small_corpus=True)
        self.assertTrue(failed)

    def test_chronic_uncertainty_on_correct_builds_fails(self) -> None:
        rows = (
            [verification_row() for _ in range(10)]
            + [verification_row(expected="complete", produced="uncertain") for _ in range(4)]
        )
        report, failed = score_verification(rows, allow_small_corpus=True)
        self.assertTrue(failed)
        self.assertGreater(report["uncertain_on_correct_rate"], VERIFICATION_UNCERTAIN_ON_CORRECT_CEILING)

    def test_small_corpus_fails_without_the_flag(self) -> None:
        rows = [verification_row() for _ in range(MINIMUM_CORPUS_ROWS - 1)]
        with self.assertRaisesRegex(SystemExit, "verification corpus"):
            score_verification(rows, allow_small_corpus=False)


class RegistrationScoringTests(unittest.TestCase):
    def test_clean_results_pass(self) -> None:
        rows = (
            [registration_row() for _ in range(35)]
            + [registration_row(ambiguity_expected=True, reported_ambiguous=True) for _ in range(5)]
        )
        report, failed = score_registration(rows, allow_small_corpus=False)
        self.assertFalse(failed)
        self.assertEqual(report["ambiguity_recall"], 1.0)

    def test_missed_ambiguity_fails(self) -> None:
        rows = (
            [registration_row() for _ in range(30)]
            + [registration_row(ambiguity_expected=True, reported_ambiguous=False) for _ in range(5)]
        )
        _, failed = score_registration(rows, allow_small_corpus=True)
        self.assertTrue(failed)

    def test_symmetric_fixtures_do_not_count_against_convergence(self) -> None:
        rows = (
            [registration_row() for _ in range(20)]
            + [registration_row(converged=False, ambiguity_expected=True, reported_ambiguous=True) for _ in range(10)]
        )
        report, failed = score_registration(rows, allow_small_corpus=True)
        self.assertFalse(failed)
        self.assertEqual(report["convergence_rate"], 1.0)

    def test_sloppy_converged_fits_fail_rmse(self) -> None:
        rows = [registration_row(translation=0.006) for _ in range(20)]
        _, failed = score_registration(rows, allow_small_corpus=True)
        self.assertTrue(failed)

    def test_sloppy_converged_fits_fail_yaw_rmse(self) -> None:
        rows = [registration_row(yaw=REGISTRATION_YAW_RMSE_DEGREES + 1.0) for _ in range(20)]
        _, failed = score_registration(rows, allow_small_corpus=True)
        self.assertTrue(failed)

    def test_small_corpus_fails_without_the_flag(self) -> None:
        rows = [registration_row() for _ in range(MINIMUM_CORPUS_ROWS - 1)]
        with self.assertRaisesRegex(SystemExit, "registration corpus"):
            score_registration(rows, allow_small_corpus=False)


class RecoveryScoringTests(unittest.TestCase):
    @staticmethod
    def mixed_method_rows(
        *,
        geometric_latency: int = 4_000,
        composite_latency: int = 12_000,
        vlm_latency: int = 12_000,
    ) -> list[dict[str, object]]:
        rows: list[dict[str, object]] = []
        for method, latency in (
            ("geometric", geometric_latency),
            ("composite", composite_latency),
            ("vlm", vlm_latency),
        ):
            rows.extend(
                benchmark_row(estimator_method=method, latency=latency) for _ in range(4)
            )
        return rows

    def test_each_method_reports_its_own_latency_median(self) -> None:
        report, failed = score_recovery(self.mixed_method_rows(), allow_small_corpus=True)
        self.assertFalse(failed)
        self.assertEqual(report["geometric_cases"], 4)
        self.assertEqual(report["composite_cases"], 4)
        self.assertEqual(report["vlm_cases"], 4)
        self.assertEqual(report["geometric_median_latency_ms"], 4_000)
        self.assertEqual(report["composite_median_latency_ms"], 12_000)
        self.assertEqual(report["vlm_median_latency_ms"], 12_000)

    def test_slow_geometric_median_fails_its_gate(self) -> None:
        _, failed = score_recovery(
            self.mixed_method_rows(geometric_latency=9_000), allow_small_corpus=True
        )
        self.assertTrue(failed)

    def test_slow_composite_median_fails_its_gate(self) -> None:
        _, failed = score_recovery(
            self.mixed_method_rows(composite_latency=21_000), allow_small_corpus=True
        )
        self.assertTrue(failed)

    def test_slow_vlm_median_fails_the_composite_gate(self) -> None:
        # A VLM-only run has no geometric leg to blame, but it spends the same
        # budget, so it is judged against the same ceiling.
        _, failed = score_recovery(
            self.mixed_method_rows(vlm_latency=21_000), allow_small_corpus=True
        )
        self.assertTrue(failed)

    def test_geometric_rows_are_not_charged_the_composite_budget(self) -> None:
        # The regression this whole field exists to prevent: before
        # estimator_method, every row bucketed as composite because the scorer
        # read a prefix off a field the row schema never carried, so a
        # geometric row at 9 s passed the 20 s gate and geometric_cases read 0.
        rows = [benchmark_row(estimator_method="geometric", latency=9_000) for _ in range(4)]
        report, failed = score_recovery(rows, allow_small_corpus=True)
        self.assertEqual(report["geometric_cases"], 4)
        self.assertEqual(report["composite_cases"], 0)
        self.assertTrue(failed)

    def test_unknown_estimator_method_is_rejected(self) -> None:
        rows = [benchmark_row(estimator_method="magic")]
        with self.assertRaisesRegex(SystemExit, "invalid estimator_method"):
            validate_rows(rows)

    def test_missing_estimator_method_is_named_in_the_error(self) -> None:
        row = benchmark_row()
        del row["estimator_method"]
        with self.assertRaisesRegex(SystemExit, "missing fields: estimator_method"):
            validate_rows([row])


class MainTests(unittest.TestCase):
    @staticmethod
    def mixed_kind_rows(*, ambiguity_reported: bool = True) -> list[dict[str, object]]:
        return [
            benchmark_row(),
            verification_row(),
            registration_row(ambiguity_expected=True, reported_ambiguous=ambiguity_reported),
        ]

    @staticmethod
    def run_main(rows: list[dict[str, object]]) -> tuple[int, str]:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "results.ndjson"
            path.write_text("\n".join(json.dumps(row) for row in rows) + "\n")
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                try:
                    main(path, allow_small_corpus=True)
                except SystemExit as caught:
                    return int(caught.code or 0), stdout.getvalue()
        raise AssertionError("main() must exit via SystemExit")

    def test_every_present_kind_is_scored(self) -> None:
        code, output = self.run_main(self.mixed_kind_rows())
        self.assertEqual(code, 0)
        headline, _, report_json = output.partition("\n")
        self.assertTrue(headline.startswith("FALSE_COMPLETE_RATE "))
        report = json.loads(report_json)
        self.assertEqual(sorted(report), ["recovery", "registration", "verification"])

    def test_failed_is_the_union_of_kind_failures(self) -> None:
        code, output = self.run_main(self.mixed_kind_rows(ambiguity_reported=False))
        self.assertEqual(code, 1)
        report = json.loads(output.partition("\n")[2])
        self.assertEqual(sorted(report), ["recovery", "registration", "verification"])


if __name__ == "__main__":
    unittest.main()
