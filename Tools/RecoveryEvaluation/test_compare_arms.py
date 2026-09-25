from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from compare_arms import Arm, compare, holm, mcnemar_exact, slot_histogram


def write(path: Path, rows: list[dict[str, object]]) -> None:
    path.write_text("\n".join(json.dumps(row) for row in rows) + "\n")


def pass_row(trace: int, correct: bool | None, latency: int = 10_000, chosen: str = "B", truth: str | None = "B") -> dict[str, object]:
    return {"trace_id": f"t{trace}", "latency_ms": latency,
            "outcome": {"top1_correct": correct, "chosen_slot": chosen, "truth_slot": truth,
                        "truth_in_candidates": truth is not None}}


def session_row(fixture: int, right: bool, certainty: str = "high") -> dict[str, object]:
    return {"fixture_id": f"f{fixture}", "expected_step_id": "m#2", "certainty": certainty,
            "ranked_step_ids": ["m#2" if right else "m#3"]}


class StatisticsTests(unittest.TestCase):
    def test_exact_mcnemar(self) -> None:
        self.assertAlmostEqual(mcnemar_exact(6, 0), 0.03125)
        self.assertAlmostEqual(mcnemar_exact(5, 0), 0.0625, msg="five clean wins are not enough")
        self.assertAlmostEqual(mcnemar_exact(5, 1), 2 * (1 + 6) / 64)
        self.assertEqual(mcnemar_exact(0, 0), 1.0)
        self.assertEqual(mcnemar_exact(3, 3), 1.0)

    def test_holm_is_monotone_and_scales_the_smallest_most(self) -> None:
        self.assertEqual(holm([0.01, 0.04, 0.03]), [0.03, 0.06, 0.06])
        self.assertEqual(holm([0.5]), [0.5])


class ComparisonTests(unittest.TestCase):
    def arms(self, control_rows, variant_rows, control_sessions=(), variant_sessions=()):
        directory = Path(tempfile.mkdtemp())
        control, variant = directory / "control.ndjson", directory / "variant.ndjson"
        write(control, list(control_sessions)); write(Path(f"{control}.traces.ndjson"), control_rows)
        write(variant, list(variant_sessions)); write(Path(f"{variant}.traces.ndjson"), variant_rows)
        return Arm.load(control), Arm.load(variant)

    def test_six_clean_wins_make_a_flip_candidate(self) -> None:
        control, variant = self.arms(
            [pass_row(i, i >= 6) for i in range(10)],
            [pass_row(i, True) for i in range(10)],
        )
        verdict = compare(control, [variant])[0]
        self.assertEqual((verdict.accuracy["pass_top1"].wins, verdict.accuracy["pass_top1"].losses), (6, 0))
        self.assertIn("FLIP CANDIDATE: accuracy win", verdict.decision)

    def test_passes_without_the_truth_on_the_board_are_not_paired(self) -> None:
        control, variant = self.arms(
            [pass_row(0, None, truth=None), pass_row(1, True)],
            [pass_row(0, None, truth=None), pass_row(1, True)],
        )
        self.assertEqual(compare(control, [variant])[0].accuracy["pass_top1"].pairs, 1)

    def test_latency_win_without_accuracy_loss_is_a_candidate(self) -> None:
        control, variant = self.arms(
            [pass_row(i, True, latency=10_000) for i in range(5)],
            [pass_row(i, True, latency=9_000) for i in range(5)],
        )
        verdict = compare(control, [variant])[0]
        self.assertAlmostEqual(verdict.latency["geometric_mean"], 0.9)
        self.assertIn("latency win", verdict.decision)

    def test_a_rise_in_insufficient_holds_the_flip(self) -> None:
        control, variant = self.arms(
            [pass_row(i, i >= 6) for i in range(10)],
            [pass_row(i, True) for i in range(10)],
            control_sessions=[session_row(0, True)],
            variant_sessions=[session_row(0, False, certainty="insufficient")],
        )
        self.assertIn("HOLD", compare(control, [variant])[0].decision)

    def test_slot_histogram_exposes_positional_bias(self) -> None:
        control, _ = self.arms(
            [pass_row(0, False, chosen="B", truth="A"), pass_row(1, True, chosen="B", truth="B"),
             pass_row(2, False, chosen="B", truth="C")],
            [],
        )
        self.assertEqual(slot_histogram(control), {"chosen": {"A": 0, "B": 3, "C": 0}, "truth": {"A": 1, "B": 1, "C": 1}})


if __name__ == "__main__":
    unittest.main()
