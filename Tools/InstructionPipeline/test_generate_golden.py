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


if __name__ == "__main__":
    unittest.main()
