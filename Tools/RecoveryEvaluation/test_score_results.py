from __future__ import annotations

import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path

from score_results import (
    DORMANT,
    FAIL,
    MINIMUM_AUTHORED_MODELS,
    PASS,
    REGISTRATION_YAW_RMSE_DEGREES,
    UNMEASURED,
    VERIFICATION_UNCERTAIN_ON_CORRECT_CEILING,
    clopper_pearson_lower,
    clopper_pearson_upper,
    evaluate,
    main,
    median_upper_bound,
    partition,
    score_recovery,
    score_registration,
    score_verification,
    validate_release_corpus,
    validate_rows,
    validate_triad_release,
    score_challenge,
)

RELEASE_ROWS = 60


def gate_named(gates, name):
    return next(gate for gate in gates if gate.name == name)


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
                score_verification([verification_row(latency=latency)])

    def test_registration_rejects_non_finite_measurements(self) -> None:
        for field, value in (
            ("translation_error_m", float("nan")),
            ("yaw_error_degrees", float("inf")),
            ("latency_ms", -3),
        ):
            row = registration_row()
            row[field] = value
            with self.assertRaisesRegex(SystemExit, field):
                score_registration([row])


class ReleaseCorpusValidationTests(unittest.TestCase):
    @staticmethod
    def release_rows(fixture_id: str | None = None) -> list[dict[str, object]]:
        rows: list[dict[str, object]] = []
        for index in range(RELEASE_ROWS):
            row = benchmark_row()
            row.update(
                fixture_id=fixture_id or f"fixture-{index}",
                physical_case=True,
                authored_model_id=f"model-{index % MINIMUM_AUTHORED_MODELS}",
                legal_use_confirmed=True,
                lighting_condition="daylight" if index % 2 else "indoor",
                capture_angle="left,center,right",
                occlusion_condition="none" if index % 2 else "partial",
                device_model="iPhone18,1",
                capture_elevation_degrees=25.0 if index % 3 == 0 else 50.0,
            )
            rows.append(row)
        return rows

    def assert_rejected(self, pattern: str, **changes: object) -> None:
        rows = self.release_rows()
        rows[3].update(changes)
        with self.assertRaisesRegex(SystemExit, pattern):
            validate_release_corpus(rows)

    def test_replay_rows_are_not_device_evidence(self) -> None:
        # The harness copies physical_case and legal_use_confirmed from the
        # staged declaration, so only device_model tells a replay apart.
        self.assert_rejected("not a physical iPhone identifier", device_model="replay:Mac14,12")

    def test_macs_ipads_and_simulators_are_rejected(self) -> None:
        for identifier in ("Mac14,12", "iPad16,3", "arm64", "iPhone"):
            self.assert_rejected("not a physical iPhone identifier", device_model=identifier)

    def test_phones_below_the_floor_are_rejected(self) -> None:
        self.assert_rejected("below the device floor", device_model="iPhone17,1")

    def test_future_pro_identifiers_pass(self) -> None:
        rows = self.release_rows()
        rows[3]["device_model"] = "iPhone19,2"
        validate_release_corpus(rows)

    def test_challenge_and_expected_failure_rows_are_rejected(self) -> None:
        self.assert_rejected("not release evidence", expected_failure=True)
        self.assert_rejected("not release evidence", challenge_class="colour_swap")

    def test_capture_angle_is_the_set_of_views_captured(self) -> None:
        # Every full session writes "left,center,right". The old rule demanded
        # two distinct values across the corpus, which real data never has.
        for accepted in ("left,center,right", "center,left", "right, center"):
            rows = self.release_rows()
            rows[3]["capture_angle"] = accepted
            validate_release_corpus(rows)
        self.assert_rejected("needs the center view", capture_angle="left,right")
        self.assert_rejected("needs the center view", capture_angle="center")
        self.assert_rejected("unknown views", capture_angle="center,above")
        self.assert_rejected("repeats a view", capture_angle="center,center")

    def test_complete_physical_corpus_passes_preflight(self) -> None:
        rows = self.release_rows()
        validate_rows(rows)
        validate_release_corpus(rows)

    def test_duplicated_fixture_ids_fail_preflight(self) -> None:
        # A repeated fixture would pad every bound's sample size with
        # correlated evidence, so it is rejected outright rather than counted.
        with self.assertRaisesRegex(SystemExit, "repeats fixture_id"):
            validate_release_corpus(self.release_rows(fixture_id="fixture-repeated"))

    def test_release_row_requires_explicit_provenance(self) -> None:
        rows = [benchmark_row() for _ in range(RELEASE_ROWS)]
        with self.assertRaisesRegex(SystemExit, "missing fields"):
            validate_release_corpus(rows)


class ElevationVarietyTests(unittest.TestCase):
    def test_one_elevation_band_fails_release(self) -> None:
        rows = ReleaseCorpusValidationTests.release_rows()
        for row in rows:
            row["capture_elevation_degrees"] = 45.0
        with self.assertRaisesRegex(SystemExit, "two viewing-elevation bands"):
            validate_release_corpus(rows)

    def test_elevation_must_be_a_measured_angle(self) -> None:
        for bad in (None, float("nan"), 120.0, "steep"):
            rows = ReleaseCorpusValidationTests.release_rows()
            rows[5]["capture_elevation_degrees"] = bad
            with self.assertRaisesRegex(SystemExit, "capture_elevation_degrees"):
                validate_release_corpus(rows)

    def test_missing_elevation_is_a_missing_release_field(self) -> None:
        rows = ReleaseCorpusValidationTests.release_rows()
        del rows[0]["capture_elevation_degrees"]
        with self.assertRaisesRegex(SystemExit, "missing fields: capture_elevation_degrees"):
            validate_release_corpus(rows)


def challenge_row(challenge_class: str, expected: str, produced: str, *, expected_failure: bool = False) -> dict[str, object]:
    return {
        "kind": "verification_challenge",
        "schema_version": 1,
        "provenance": "synthetic",
        "fixture_id": f"challenge-{challenge_class}",
        "challenge_class": challenge_class,
        "expected_verdict": expected,
        "produced_verdict": produced,
        "expected_failure": expected_failure,
        "detectability": "strong",
        "latency_ms": 900,
    }


class ChallengeScoringTests(unittest.TestCase):
    ROWS = [
        challenge_row("plate_up1", "misplaced", "complete"),
        challenge_row("plate_up1", "misplaced", "uncertain"),
        challenge_row("shift1z", "misplaced", "misplaced"),
        challenge_row("rot180_symmetric", "complete", "complete"),
        challenge_row("rot180_symmetric", "complete", "misplaced"),
        challenge_row("colour_swap", "misplaced", "complete", expected_failure=True),
        challenge_row("colour_swap", "misplaced", "uncertain", expected_failure=True),
    ]

    def test_per_class_accounting(self) -> None:
        report = score_challenge(self.ROWS)
        plate = report["by_class"]["plate_up1"]
        self.assertEqual((plate["cases"], plate["false_complete_cases"], plate["abstained"]), (2, 1, 1))
        self.assertEqual(report["by_class"]["shift1z"]["caught"], 1)
        symmetric = report["by_class"]["rot180_symmetric"]
        self.assertEqual((symmetric["correct_complete"], symmetric["false_alarms"]), (1, 1))

    def test_expected_failures_are_counted_apart(self) -> None:
        report = score_challenge(self.ROWS)
        colour = report["by_class"]["colour_swap"]
        self.assertEqual((colour["xfail"], colour["xpass"]), (1, 1))
        self.assertEqual(report["false_complete_cases"], 1, "only plate_up1's false complete is unexpected")
        self.assertEqual(report["expected_failure_false_complete_cases"], 1)

    def test_challenge_lines_print_after_the_headline_and_never_gate(self) -> None:
        code, output = MainTests.run_main(self.ROWS)
        self.assertEqual(code, 0)
        lines = output.splitlines()
        self.assertTrue(lines[0].startswith("FALSE_COMPLETE_RATE"))
        self.assertIn("CHALLENGE_FALSE_COMPLETE plate_up1 1/2", lines)
        self.assertIn("CHALLENGE_FALSE_COMPLETE colour_swap 1/2 XFAIL", lines)

    def test_challenge_rows_are_not_release_evidence(self) -> None:
        code, output = MainTests.run_main(self.ROWS, informational=False)
        self.assertEqual(code, 1)
        self.assertIn("not release evidence", output)


class TriadReleaseProvenanceTests(unittest.TestCase):
    def test_synthetic_triad_rows_fail_release_mode(self) -> None:
        rows = [verification_row(expected="incomplete", produced="incomplete") for _ in range(200)]
        code, output = MainTests.run_main(rows, informational=False, require_kinds={"verification"})
        self.assertEqual(code, 1)
        self.assertIn("provenance None", output)

    def test_device_triad_rows_need_an_admitted_device_and_model(self) -> None:
        row = verification_row()
        row.update(provenance="device", device_model="iPhone18,2", authored_model_id="model-1")
        validate_triad_release([row], "verification")
        for field, value, pattern in (
            ("device_model", "replay:Mac14,12", "not a physical iPhone"),
            ("authored_model_id", "", "authored_model_id"),
        ):
            broken = dict(row)
            broken[field] = value
            with self.assertRaisesRegex(SystemExit, pattern):
                validate_triad_release([broken], "verification")


class PartitionTests(unittest.TestCase):
    def test_rows_without_kind_default_to_recovery(self) -> None:
        kinds = partition([benchmark_row(), verification_row(), registration_row()])
        self.assertEqual(len(kinds["recovery"]), 1)
        self.assertEqual(len(kinds["verification"]), 1)
        self.assertEqual(len(kinds["registration"]), 1)

    def test_synthetic_summary_passes_through_but_is_not_release_evidence(self) -> None:
        summary = {"kind": "synthetic_summary", "schema_version": 1, "suite": "regression", "steps_sampled": 3}
        self.assertEqual(partition([summary])["synthetic_summary"], [summary])
        code, output = MainTests.run_main([benchmark_row(), summary])
        self.assertEqual(code, 0)
        self.assertEqual(MainTests.report_json(output)["synthetic_summary"], [summary])
        code, output = MainTests.run_main([benchmark_row(), summary], informational=False)
        self.assertEqual(code, 1)
        self.assertIn("not release evidence", output)

    def test_unknown_kind_is_rejected(self) -> None:
        with self.assertRaisesRegex(SystemExit, "unknown kind"):
            partition([{"kind": "telemetry"}])


class VerificationScoringTests(unittest.TestCase):
    @staticmethod
    def release_sized_clean_rows() -> list[dict[str, object]]:
        # Just past every zero-miss minimum: 149 negatives for the 2%
        # false-complete ceiling, 59 undetectable rows for 95% abstention.
        return (
            [verification_row() for _ in range(60)]
            + [verification_row(expected="incomplete", produced="incomplete") for _ in range(150)]
            + [verification_row(expected="uncertain", produced="uncertain", detectability="undetectable") for _ in range(60)]
        )

    def test_clean_release_sized_results_pass_all_gates(self) -> None:
        report, gates = score_verification(self.release_sized_clean_rows())
        self.assertFalse(evaluate(gates, release=True))
        self.assertEqual(report["false_complete_rate"], 0.0)
        self.assertEqual(report["negatives"], 150)
        self.assertLessEqual(report["false_complete_upper_95"], 0.02)
        self.assertEqual(report["undetectable_abstention_rate"], 1.0)

    def test_clean_but_small_results_fail_release_on_their_bounds(self) -> None:
        # 40 perfect negatives prove a false-complete rate below ~7.2%, not
        # below 2%: a flawless small sample is not release evidence.
        rows = (
            [verification_row() for _ in range(40)]
            + [verification_row(expected="incomplete", produced="incomplete") for _ in range(40)]
            + [verification_row(expected="uncertain", produced="uncertain", detectability="undetectable") for _ in range(20)]
        )
        _, gates = score_verification(rows)
        self.assertFalse(evaluate(gates, release=False))
        self.assertTrue(evaluate(gates, release=True))
        self.assertEqual(gate_named(gates, "verification.false_complete_rate").status(release=True), FAIL)

    def test_no_negatives_is_unmeasured_not_zero(self) -> None:
        # The defect this replaces: an all-complete corpus used to report a
        # perfect 0.0 false-complete rate while measuring nothing.
        report, gates = score_verification([verification_row() for _ in range(200)])
        self.assertIsNone(report["false_complete_rate"])
        self.assertIsNone(report["false_complete_upper_95"])
        self.assertEqual(report["negatives"], 0)
        gate = gate_named(gates, "verification.false_complete_rate")
        self.assertEqual(gate.status(release=True), UNMEASURED)
        self.assertTrue(gate.fails(release=True))
        self.assertFalse(gate.fails(release=False))

    def test_false_complete_is_the_headline_gate(self) -> None:
        # 3 wrong "complete" verdicts in 40 negatives is 7.5% — over the 2%
        # ceiling even though everything else is perfect.
        rows = (
            [verification_row() for _ in range(60)]
            + [verification_row(expected="incomplete", produced="incomplete") for _ in range(37)]
            + [verification_row(expected="incomplete", produced="complete") for _ in range(3)]
        )
        report, gates = score_verification(rows)
        self.assertTrue(evaluate(gates, release=False))
        self.assertTrue(evaluate(gates, release=True))
        self.assertGreater(report["false_complete_rate"], 0.02)

    def test_complete_on_undetectable_is_a_hard_failure_in_both_modes(self) -> None:
        rows = (
            [verification_row() for _ in range(20)]
            + [verification_row(expected="uncertain", produced="complete", detectability="undetectable") for _ in range(5)]
        )
        report, gates = score_verification(rows)
        self.assertEqual(report["undetectable_false_completes"], 5)
        gate = gate_named(gates, "verification.undetectable_false_completes")
        self.assertTrue(gate.fails(release=False))
        self.assertTrue(gate.fails(release=True))

    def test_chronic_uncertainty_on_correct_builds_fails(self) -> None:
        rows = (
            [verification_row() for _ in range(10)]
            + [verification_row(expected="complete", produced="uncertain") for _ in range(4)]
        )
        report, gates = score_verification(rows)
        self.assertTrue(evaluate(gates, release=False))
        self.assertGreater(report["uncertain_on_correct_rate"], VERIFICATION_UNCERTAIN_ON_CORRECT_CEILING)

    def test_marginal_gates_are_dormant(self) -> None:
        # Marginal complete is blocked until the RGB term exists (ADR 0008);
        # zero marginal recall must be reported, never fail the run.
        rows = self.release_sized_clean_rows() + [
            verification_row(detectability="marginal", produced="incomplete") for _ in range(10)
        ]
        report, gates = score_verification(rows)
        self.assertEqual(report["per_detectability"]["marginal"]["complete_recall"], 0.0)
        gate = gate_named(gates, "verification.marginal.complete_recall")
        self.assertEqual(gate.status(release=True), DORMANT)
        self.assertFalse(evaluate(gates, release=True))


class RegistrationScoringTests(unittest.TestCase):
    def test_clean_release_sized_results_pass(self) -> None:
        rows = (
            [registration_row() for _ in range(60)]
            + [registration_row(ambiguity_expected=True, reported_ambiguous=True) for _ in range(30)]
        )
        report, gates = score_registration(rows)
        self.assertFalse(evaluate(gates, release=True))
        self.assertEqual(report["ambiguity_recall"], 1.0)

    def test_missed_ambiguity_fails(self) -> None:
        rows = (
            [registration_row() for _ in range(30)]
            + [registration_row(ambiguity_expected=True, reported_ambiguous=False) for _ in range(5)]
        )
        _, gates = score_registration(rows)
        self.assertTrue(evaluate(gates, release=False))

    def test_symmetric_fixtures_do_not_count_against_convergence(self) -> None:
        rows = (
            [registration_row() for _ in range(20)]
            + [registration_row(converged=False, ambiguity_expected=True, reported_ambiguous=True) for _ in range(10)]
        )
        report, gates = score_registration(rows)
        self.assertFalse(evaluate(gates, release=False))
        self.assertEqual(report["convergence_rate"], 1.0)

    def test_sloppy_converged_fits_fail_rmse(self) -> None:
        rows = [registration_row(translation=0.006) for _ in range(20)]
        _, gates = score_registration(rows)
        self.assertTrue(evaluate(gates, release=False))

    def test_sloppy_converged_fits_fail_yaw_rmse(self) -> None:
        rows = [registration_row(yaw=REGISTRATION_YAW_RMSE_DEGREES + 1.0) for _ in range(20)]
        _, gates = score_registration(rows)
        self.assertTrue(evaluate(gates, release=False))

    def test_few_converged_fits_leave_rmse_unmeasured_in_release(self) -> None:
        rows = [registration_row() for _ in range(10)]
        report, gates = score_registration(rows)
        self.assertIsNotNone(report["translation_rmse_m"])
        gate = gate_named(gates, "registration.translation_rmse_m")
        self.assertEqual(gate.status(release=False), PASS)
        self.assertEqual(gate.status(release=True), UNMEASURED)

    def test_sweep_without_ambiguity_fixtures_cannot_pass_release(self) -> None:
        # The synthetic sweep sets no ambiguity-expected rows; that gate used
        # to be silently skipped, which read as a pass.
        _, gates = score_registration([registration_row() for _ in range(80)])
        gate = gate_named(gates, "registration.ambiguity_recall")
        self.assertEqual(gate.status(release=True), UNMEASURED)
        self.assertTrue(evaluate(gates, release=True))
        self.assertFalse(evaluate(gates, release=False))


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
        report, gates = score_recovery(self.mixed_method_rows(), release=False)
        self.assertFalse(evaluate(gates, release=False))
        self.assertEqual(report["geometric_cases"], 4)
        self.assertEqual(report["composite_cases"], 4)
        self.assertEqual(report["vlm_cases"], 4)
        self.assertEqual(report["geometric_median_latency_ms"], 4_000)
        self.assertEqual(report["composite_median_latency_ms"], 12_000)
        self.assertEqual(report["vlm_median_latency_ms"], 12_000)

    def test_slow_geometric_median_fails_its_gate(self) -> None:
        _, gates = score_recovery(self.mixed_method_rows(geometric_latency=9_000), release=False)
        self.assertTrue(evaluate(gates, release=False))

    def test_slow_composite_median_fails_its_gate(self) -> None:
        _, gates = score_recovery(self.mixed_method_rows(composite_latency=21_000), release=False)
        self.assertTrue(evaluate(gates, release=False))

    def test_slow_vlm_median_fails_the_composite_gate(self) -> None:
        # A VLM-only run has no geometric leg to blame, but it spends the same
        # budget, so it is judged against the same ceiling.
        _, gates = score_recovery(self.mixed_method_rows(vlm_latency=21_000), release=False)
        self.assertTrue(evaluate(gates, release=False))

    def test_geometric_rows_are_not_charged_the_composite_budget(self) -> None:
        # The regression this whole field exists to prevent: before
        # estimator_method, every row bucketed as composite because the scorer
        # read a prefix off a field the row schema never carried, so a
        # geometric row at 9 s passed the 20 s gate and geometric_cases read 0.
        rows = [benchmark_row(estimator_method="geometric", latency=9_000) for _ in range(4)]
        report, gates = score_recovery(rows, release=False)
        self.assertEqual(report["geometric_cases"], 4)
        self.assertEqual(report["composite_cases"], 0)
        self.assertTrue(evaluate(gates, release=False))

    def test_empty_required_latency_bucket_is_unmeasured_not_zero_ms(self) -> None:
        # The defect this replaces: `(median or 0) > limit` passed an empty
        # bucket as "0 ms". Geometric is the primary path, so a release corpus
        # without it has not measured the gate.
        rows = [benchmark_row(estimator_method="composite") for _ in range(10)]
        report, gates = score_recovery(rows, release=False)
        self.assertIsNone(report["geometric_median_latency_ms"])
        geometric = gate_named(gates, "recovery.geometric_median_latency_ms")
        self.assertEqual(geometric.status(release=True), UNMEASURED)
        self.assertTrue(geometric.fails(release=True))
        self.assertFalse(geometric.fails(release=False))

    def test_empty_vlm_bucket_is_optional(self) -> None:
        rows = [benchmark_row(estimator_method="geometric", latency=4_000) for _ in range(10)]
        _, gates = score_recovery(rows, release=False)
        vlm = gate_named(gates, "recovery.vlm_median_latency_ms")
        self.assertEqual(vlm.status(release=True), UNMEASURED)
        self.assertFalse(vlm.fails(release=True))

    def test_unknown_estimator_method_is_rejected(self) -> None:
        rows = [benchmark_row(estimator_method="magic")]
        with self.assertRaisesRegex(SystemExit, "invalid estimator_method"):
            validate_rows(rows)

    def test_missing_estimator_method_is_named_in_the_error(self) -> None:
        row = benchmark_row()
        del row["estimator_method"]
        with self.assertRaisesRegex(SystemExit, "missing fields: estimator_method"):
            validate_rows([row])


class BenchmarkProtocolTests(unittest.TestCase):
    def test_latency_is_reported_per_bucket(self) -> None:
        rows = []
        for bucket, latency in (("cold", 18_000), ("warm", 9_000), ("warm", 11_000), ("sustained", 14_000)):
            row = benchmark_row(latency=latency)
            row["latency_bucket"] = bucket
            rows.append(row)
        rows.append(benchmark_row(latency=5_000))
        report, _ = score_recovery(rows, release=False)
        buckets = report["latency_by_bucket"]
        self.assertEqual(buckets["warm"], {"cases": 2, "p50_ms": 10_000.0, "p95_ms": 10_900.0})
        self.assertEqual(buckets["cold"]["cases"], 1)
        self.assertEqual(buckets["unbucketed"]["cases"], 1)

    def test_mixed_arms_are_refused_unless_allowed(self) -> None:
        baseline, variant = benchmark_row(), benchmark_row()
        baseline["variant_id"] = "baseline"
        variant["variant_id"] = "decode=feed_all"
        code, output = MainTests.run_main([baseline, variant])
        self.assertEqual(code, 1)
        self.assertIn("2 inference variants", output)
        code, _ = MainTests.run_main([baseline, variant], allow_mixed_arms=True)
        self.assertEqual(code, 0)


class MainTests(unittest.TestCase):
    @staticmethod
    def mixed_kind_rows(*, ambiguity_reported: bool = True) -> list[dict[str, object]]:
        return [
            benchmark_row(),
            verification_row(),
            registration_row(ambiguity_expected=True, reported_ambiguous=ambiguity_reported),
        ]

    @staticmethod
    def run_main(rows: list[dict[str, object]], **options: object) -> tuple[int, str]:
        options.setdefault("informational", True)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "results.ndjson"
            path.write_text("\n".join(json.dumps(row) for row in rows) + "\n")
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                try:
                    main(path, **options)
                except SystemExit as caught:
                    # A validation failure exits with its message as the code.
                    if isinstance(caught.code, str):
                        return 1, stdout.getvalue() + caught.code
                    return int(caught.code or 0), stdout.getvalue()
        raise AssertionError("main() must exit via SystemExit")

    @staticmethod
    def report_json(output: str) -> dict[str, object]:
        return json.loads(output[output.index("\n{") + 1:])

    def test_every_present_kind_is_scored(self) -> None:
        code, output = self.run_main(self.mixed_kind_rows())
        self.assertEqual(code, 0)
        self.assertTrue(output.startswith("FALSE_COMPLETE_RATE "))
        report = self.report_json(output)
        self.assertEqual(sorted(report), ["recovery", "registration", "verification"])
        self.assertIn("verification.false_complete_rate", report["verification"]["gates"])

    def test_failed_is_the_union_of_kind_failures(self) -> None:
        code, output = self.run_main(self.mixed_kind_rows(ambiguity_reported=False))
        self.assertEqual(code, 1)
        report = self.report_json(output)
        self.assertEqual(sorted(report), ["recovery", "registration", "verification"])

    def test_headline_prints_even_without_verification_rows(self) -> None:
        code, output = self.run_main([benchmark_row()])
        self.assertEqual(code, 0)
        self.assertTrue(output.startswith(f"FALSE_COMPLETE_RATE {UNMEASURED}"))
        self.assertIn(f"KIND verification {UNMEASURED}", output)

    def test_missing_required_kind_fails_and_is_named(self) -> None:
        code, output = self.run_main([benchmark_row()], require_kinds={"registration"})
        self.assertEqual(code, 1)
        self.assertIn("KIND registration UNMEASURED (required: FAIL)", output)


class ConfidenceBoundTests(unittest.TestCase):
    def test_zero_event_upper_bound_has_the_closed_form(self) -> None:
        for trials in (1, 10, 149):
            self.assertAlmostEqual(clopper_pearson_upper(0, trials), 1 - 0.05 ** (1 / trials), places=12)

    def test_false_complete_needs_149_clean_negatives(self) -> None:
        self.assertLessEqual(clopper_pearson_upper(0, 149), 0.02)
        self.assertGreater(clopper_pearson_upper(0, 148), 0.02)

    def test_forty_of_forty_only_demonstrates_about_093(self) -> None:
        self.assertAlmostEqual(clopper_pearson_lower(40, 40), 0.9278, places=3)

    def test_interior_bound_matches_the_reference_value(self) -> None:
        # One event in ten: the one-sided 95% upper bound is 0.3942.
        self.assertAlmostEqual(clopper_pearson_upper(1, 10), 0.3942, places=3)

    def test_lower_bound_mirrors_the_upper_bound(self) -> None:
        for events, trials in ((0, 5), (3, 17), (12, 12)):
            self.assertAlmostEqual(
                clopper_pearson_lower(events, trials),
                1 - clopper_pearson_upper(trials - events, trials),
                places=12,
            )

    def test_edges(self) -> None:
        self.assertEqual(clopper_pearson_upper(7, 7), 1.0)
        self.assertEqual(clopper_pearson_lower(0, 7), 0.0)
        self.assertIsNone(clopper_pearson_upper(0, 0))
        self.assertIsNone(clopper_pearson_lower(0, 0))

    def test_median_bound_needs_five_samples(self) -> None:
        self.assertIsNone(median_upper_bound([1.0, 2.0, 3.0, 4.0]))
        self.assertEqual(median_upper_bound([5.0, 1.0, 4.0, 2.0, 3.0]), 5.0)

    def test_median_bound_picks_the_qualifying_order_statistic(self) -> None:
        # n = 10: P(Bin(10, 0.5) <= 7) = 0.945 < 0.95 <= P(<= 8), so X(9).
        self.assertEqual(median_upper_bound([float(value) for value in range(1, 11)]), 9.0)


if __name__ == "__main__":
    unittest.main()
