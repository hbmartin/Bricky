from __future__ import annotations

import unittest

from score_results import (
    MINIMUM_CORPUS_ROWS,
    partition,
    score_registration,
    score_verification,
    validate_release_corpus,
    validate_rows,
)


def benchmark_row(*, certainty: str = "high", include_top: bool = True) -> dict[str, object]:
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
        "device_model": "iPhone",
        "operating_system": "iOS",
        "latency_ms": 12_000,
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
    latency: int = 1_500,
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


class ReleaseCorpusValidationTests(unittest.TestCase):
    @staticmethod
    def release_rows(fixture_id: str | None = None) -> list[dict[str, object]]:
        rows: list[dict[str, object]] = []
        for index in range(MINIMUM_CORPUS_ROWS):
            row = benchmark_row()
            row.update(
                fixture_id=fixture_id or f"fixture-{index}",
                physical_case=True,
                authored_model_id=f"model-{index % 6}",
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
        report, failed = score_verification(rows)
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
        report, failed = score_verification(rows)
        self.assertTrue(failed)
        self.assertGreater(report["false_complete_rate"], 0.02)

    def test_missing_abstention_on_undetectable_fails(self) -> None:
        rows = (
            [verification_row() for _ in range(20)]
            + [verification_row(expected="uncertain", produced="complete", detectability="undetectable") for _ in range(5)]
        )
        _, failed = score_verification(rows)
        self.assertTrue(failed)

    def test_chronic_uncertainty_on_correct_builds_fails(self) -> None:
        rows = (
            [verification_row() for _ in range(10)]
            + [verification_row(expected="complete", produced="uncertain") for _ in range(4)]
        )
        _, failed = score_verification(rows)
        self.assertTrue(failed)


class RegistrationScoringTests(unittest.TestCase):
    def test_clean_results_pass(self) -> None:
        rows = (
            [registration_row() for _ in range(30)]
            + [registration_row(ambiguity_expected=True, reported_ambiguous=True) for _ in range(5)]
        )
        report, failed = score_registration(rows)
        self.assertFalse(failed)
        self.assertEqual(report["ambiguity_recall"], 1.0)

    def test_missed_ambiguity_fails(self) -> None:
        rows = (
            [registration_row() for _ in range(30)]
            + [registration_row(ambiguity_expected=True, reported_ambiguous=False) for _ in range(5)]
        )
        _, failed = score_registration(rows)
        self.assertTrue(failed)

    def test_symmetric_fixtures_do_not_count_against_convergence(self) -> None:
        rows = (
            [registration_row() for _ in range(20)]
            + [registration_row(converged=False, ambiguity_expected=True, reported_ambiguous=True) for _ in range(10)]
        )
        report, failed = score_registration(rows)
        self.assertFalse(failed)
        self.assertEqual(report["convergence_rate"], 1.0)

    def test_sloppy_converged_fits_fail_rmse(self) -> None:
        rows = [registration_row(translation=0.006) for _ in range(20)]
        _, failed = score_registration(rows)
        self.assertTrue(failed)


if __name__ == "__main__":
    unittest.main()
