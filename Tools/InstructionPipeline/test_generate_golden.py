from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from generate_golden import has_explicit_step


class ExplicitBoundaryTests(unittest.TestCase):
    def test_rotstep_is_an_authored_boundary(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / "rotstep-only.ldr"
            fixture.write_text("0 ROTSTEP 0 90 0 REL\n", encoding="utf-8")
            self.assertTrue(has_explicit_step(fixture))

    def test_iso_latin1_fixture_uses_the_same_fallback_as_the_app(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / "latin1.ldr"
            fixture.write_bytes(b"0 caf\xe9\n0 STEP\n")
            self.assertTrue(has_explicit_step(fixture))

    def test_comment_containing_step_is_not_a_boundary(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / "comment.ldr"
            fixture.write_text("0 This mentions STEP but is not one\n", encoding="utf-8")
            self.assertFalse(has_explicit_step(fixture))

    def test_cr_only_line_endings_with_a_mid_file_boundary(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / "cr-only.ldr"
            fixture.write_bytes(
                b"0 legacy mac model\r0 STEP\r1 16 0 0 0 1 0 0 0 1 0 0 0 1 3001.dat\r"
            )
            self.assertTrue(has_explicit_step(fixture))

    def test_cr_only_rotstep_is_detected_before_the_final_line(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / "cr-only-rotstep.ldr"
            fixture.write_bytes(b"0 ROTSTEP 0 90 0 REL\r0 trailing comment\r")
            self.assertTrue(has_explicit_step(fixture))


if __name__ == "__main__":
    unittest.main()
