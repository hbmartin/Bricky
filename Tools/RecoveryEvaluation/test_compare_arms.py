from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import contextlib
import io

from compare_arms import Arm, compare, holm, main, mcnemar_exact, slot_histogram


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
            [pass_row(i, i >= 6) for i in range(20)],
            [pass_row(i, True) for i in range(20)],
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
            [pass_row(i, True, latency=10_000) for i in range(20)],
            [pass_row(i, True, latency=9_000) for i in range(20)],
        )
        verdict = compare(control, [variant])[0]
        self.assertAlmostEqual(verdict.latency["geometric_mean"], 0.9)
        self.assertIn("latency win", verdict.decision)

    def test_a_rise_in_insufficient_holds_the_flip(self) -> None:
        control, variant = self.arms(
            [pass_row(i, i >= 6) for i in range(20)],
            [pass_row(i, True) for i in range(20)],
            control_sessions=[session_row(0, True)],
            variant_sessions=[session_row(0, False, certainty="insufficient")],
        )
        self.assertIn("HOLD", compare(control, [variant])[0].decision)

    def test_too_few_pairs_is_underpowered_not_a_candidate(self) -> None:
        control, variant = self.arms(
            [pass_row(i, False, latency=10_000) for i in range(3)],
            [pass_row(i, False, latency=6_000) for i in range(3)],
        )
        self.assertIn("UNDERPOWERED", compare(control, [variant])[0].decision)

    def test_session_primary_decision(self) -> None:
        # Geometric recovery arms have sessions and no passes.
        control, variant = self.arms(
            [], [],
            control_sessions=[session_row(i, i >= 6) for i in range(20)],
            variant_sessions=[session_row(i, True) for i in range(20)],
        )
        self.assertIn("UNMEASURED", compare(control, [variant])[0].decision, "no passes to judge by default")
        verdict = compare(control, [variant], primary="session_top1")[0]
        self.assertEqual((verdict.accuracy["session_top1"].wins, verdict.accuracy["session_top1"].losses), (6, 0))
        self.assertIn("FLIP CANDIDATE: accuracy win", verdict.decision)

    def test_verification_windows_pair_by_window_and_guard_false_complete(self) -> None:
        # Colour-term arms: SyntheticRGBD --replay-bundle rows, one per window.
        def window(index: int, expected: str, produced: str) -> dict[str, object]:
            return {"kind": "verification", "fixture_id": f"w{index}", "expected_verdict": expected,
                    "produced_verdict": produced, "detectability": "marginal"}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            control_rows = [window(i, "complete", "uncertain") for i in range(20)] + [window(99, "incomplete", "incomplete")]
            variant_rows = [window(i, "complete", "complete") for i in range(20)] + [window(99, "incomplete", "incomplete")]
            write(root / "control.ndjson", control_rows)
            write(root / "variant.ndjson", variant_rows)
            control, variant = Arm.load(root / "control.ndjson"), Arm.load(root / "variant.ndjson")
            self.assertEqual(len(control.verifications), 21)
            self.assertEqual(control.sessions, {}, "verification rows are not sessions")
            verdict = compare(control, [variant], primary="verification_correct")[0]
            self.assertEqual((verdict.accuracy["verification_correct"].wins, verdict.accuracy["verification_correct"].losses), (20, 0))
            self.assertIn("FLIP CANDIDATE: accuracy win", verdict.decision)
            # A variant that completes a negative window holds, whatever it wins.
            variant_rows[-1] = window(99, "incomplete", "complete")
            write(root / "variant.ndjson", variant_rows)
            held = compare(control, [Arm.load(root / "variant.ndjson")], primary="verification_correct")[0]
            self.assertEqual(held.verification_false_complete, (0.0, 1.0))
            self.assertIn("HOLD", held.decision)

    def test_check_primary_pairs_checks(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, right in (("control", 10), ("variant", 20)):
                write(root / f"{name}.ndjson", [])
                write(root / f"{name}.ndjson.checks.ndjson", [
                    {"fixture_id": f"c{i}", "expected_verdict": "complete",
                     "produced_verdict": "complete" if i < right else "uncertain"} for i in range(20)
                ])
            verdict = compare(Arm.load(root / "control.ndjson"), [Arm.load(root / "variant.ndjson")], primary="check_correct")[0]
            self.assertEqual(verdict.accuracy["check_correct"].wins, 10)
            self.assertIn("FLIP CANDIDATE", verdict.decision)

    def test_slot_histogram_exposes_positional_bias(self) -> None:
        control, _ = self.arms(
            [pass_row(0, False, chosen="B", truth="A"), pass_row(1, True, chosen="B", truth="B"),
             pass_row(2, False, chosen="B", truth="C")],
            [],
        )
        self.assertEqual(slot_histogram(control), {"chosen": {"A": 0, "B": 3, "C": 0}, "truth": {"A": 1, "B": 1, "C": 1}})


class ArmHygieneTests(unittest.TestCase):
    """Arms that ran different weights, or an adapter scored on the data it
    trained on, are refused before any statistic is computed."""

    def run_main(self, control_rows, variant_rows, *extra: str) -> tuple[int, str]:
        directory = Path(tempfile.mkdtemp())
        control, variant = directory / "control.ndjson", directory / "variant.ndjson"
        write(control, []); write(Path(f"{control}.traces.ndjson"), control_rows)
        write(variant, []); write(Path(f"{variant}.traces.ndjson"), variant_rows)
        manifest = directory / "split_manifest.json"
        manifest.write_text(json.dumps({
            "schema": "bricky.split_manifest.v1",
            "train": {"session_ids": ["s-train"]},
            "test": {"session_ids": ["s-test"]},
        }))
        arguments = ["--control", str(control), "--variant", str(variant)]
        arguments += [str(manifest) if value == "MANIFEST" else value for value in extra]
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = main(arguments)
        return code, output.getvalue()

    @staticmethod
    def rows(revision: str | None, variant_id: str = "baseline", session: str = "s-test", count: int = 20):
        rows = []
        for index in range(count):
            row = pass_row(index, True)
            row.update({"variant_id": variant_id, "session_id": session})
            if revision is not None:
                row["model_revision"] = revision
            rows.append(row)
        return rows

    def test_mixed_model_revisions_refused(self) -> None:
        code, output = self.run_main(self.rows("rev-a"), self.rows("rev-b"))
        self.assertEqual(code, 2)
        self.assertIn("different model revisions", output)
        code, _ = self.run_main(self.rows("rev-a"), self.rows("rev-b"), "--allow-mixed-revisions")
        self.assertEqual(code, 0)

    def test_sidecars_without_a_revision_only_warn(self) -> None:
        code, output = self.run_main(self.rows(None), self.rows("rev-a"))
        self.assertEqual(code, 0)
        self.assertIn("with no model_revision", output)

    def test_adapter_arm_requires_restrict(self) -> None:
        adapter = self.rows("rev-a", variant_id="scoring=probe,adapter=first-slot@0123456789ab")
        code, output = self.run_main(self.rows("rev-a"), adapter)
        self.assertEqual(code, 2)
        self.assertIn("held-out split", output)
        code, _ = self.run_main(self.rows("rev-a"), adapter, "--restrict", "MANIFEST")
        self.assertEqual(code, 0)

    def test_restrict_limits_pairs(self) -> None:
        held_out = self.rows("rev-a", session="s-test", count=4)
        trained = [dict(row, trace_id=f"x{index}", session_id="s-train") for index, row in enumerate(self.rows("rev-a"))]
        code, output = self.run_main(held_out + trained, held_out + trained, "--restrict", "MANIFEST")
        self.assertEqual(code, 0)
        self.assertIn("restricted to 1 held-out sessions", output)
        self.assertIn("pass_top1: 4 pairs", output)


if __name__ == "__main__":
    unittest.main()
