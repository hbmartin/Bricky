from __future__ import annotations

import contextlib
import csv
import io
import tempfile
import unittest
from pathlib import Path

from score_wording_ab import Tally, main, score


def sheet_and_key(choices: list[str], model_options: list[str]) -> tuple[list[dict[str, str]], list[dict[str, str]]]:
    sheet = [{"pair_id": f"p{i}", "action": "move", "option_a": "a", "option_b": "b", "choice": choice}
             for i, choice in enumerate(choices)]
    key = [{"pair_id": f"p{i}", "model_option": option, "os_build": "24A430", "device_model": "iPhone18,1"}
           for i, option in enumerate(model_options)]
    return sheet, key


class SignTestTests(unittest.TestCase):
    def test_exact_one_sided_sign_test(self) -> None:
        self.assertAlmostEqual(Tally(wins=5, losses=0).p_value, 1 / 32)
        self.assertAlmostEqual(Tally(wins=4, losses=0).p_value, 1 / 16)
        self.assertEqual(Tally().p_value, 1.0)
        # Five clean wins are the smallest sweep that clears 0.05.
        self.assertEqual(Tally(wins=5, losses=0).decision, "MODEL PREFERRED")
        self.assertEqual(Tally(wins=4, losses=0).decision, "NO PREFERENCE")
        self.assertEqual(Tally(wins=0, losses=6).decision, "TEMPLATE PREFERRED")
        self.assertEqual(Tally().decision, "UNMEASURED (no decided pairs)")

    def test_unblinding_counts_the_model_option_and_drops_ties(self) -> None:
        sheet, key = sheet_and_key(["A", "B", "=", "", "a"], ["A", "A", "B", "B", "B"])
        tally = score(sheet, key)
        self.assertEqual((tally.wins, tally.losses, tally.ties, tally.unrated), (1, 2, 1, 1))

    def test_unknown_pairs_and_choices_are_refused(self) -> None:
        sheet, key = sheet_and_key(["A"], ["A"])
        with self.assertRaises(SystemExit):
            score(sheet, [])
        with self.assertRaises(SystemExit):
            score([dict(sheet[0], choice="maybe")], key)

    def test_main_reads_the_two_files(self) -> None:
        sheet, key = sheet_and_key(["A"] * 6, ["A"] * 6)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, rows in (("sheet.csv", sheet), ("key.csv", key)):
                with (root / name).open("w", newline="") as handle:
                    writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
                    writer.writeheader()
                    writer.writerows(rows)
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertEqual(main(["--sheet", str(root / "sheet.csv"), "--key", str(root / "key.csv")]), 0)
        self.assertIn("WORDING_PREFERENCE model 6 / template 0", output.getvalue())
        self.assertIn("VERDICT MODEL PREFERRED", output.getvalue())


if __name__ == "__main__":
    unittest.main()
