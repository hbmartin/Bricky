"""Tests for LDraw export."""
from __future__ import annotations

from app.contracts import LDU_PER_STUD, Brick
from app.ldraw import export_ldr, sort_bricks

from .conftest import palette


def test_header_present():
    text = export_ldr([], palette())
    assert text.startswith("0 Mosaic Model")
    assert "0 BFC CERTIFY CCW" in text


def test_line_format_and_coordinates():
    bricks = [Brick(x=2, y=3, length=2, color="Bright Red")]
    text = export_ldr(bricks, palette())
    # color id 4 (LDraw Bright Red), x=2*20=40, y=3*20=60, z=0, part 3023.
    assert "1 4 40 60 0 1 0 0 0 1 0 0 0 1 3023.dat" in text


def test_uses_ldu_scale():
    bricks = [Brick(x=1, y=0, length=1, color="Black")]
    text = export_ldr(bricks, palette())
    assert f" {1 * LDU_PER_STUD} 0 0 " in text


def test_deterministic_order_layer_row_col():
    bricks = [
        Brick(x=5, y=2, length=1, color="Black"),
        Brick(x=0, y=0, length=1, color="Black"),
        Brick(x=3, y=0, length=1, color="Black"),
    ]
    ordered = sort_bricks(bricks)
    assert [(b.y, b.x) for b in ordered] == [(0, 0), (0, 3), (2, 5)]


def test_one_line_per_brick():
    bricks = [
        Brick(x=0, y=0, length=1, color="Black"),
        Brick(x=1, y=0, length=1, color="White"),
    ]
    text = export_ldr(bricks, palette())
    part_lines = [ln for ln in text.splitlines() if ln.startswith("1 ")]
    assert len(part_lines) == 2


def test_ends_with_newline():
    assert export_ldr([], palette()).endswith("\n")
