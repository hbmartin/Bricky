"""LDraw export: ordered brick list -> single deterministic .ldr (LDRAW_EXPORT.md).

Coordinates are LDU (1 stud = 20). The mosaic is a vertical wall facing the builder:
X = column*20, Y = row*20 (LDraw's -Y-is-up means row 0 maps to the smallest Y, so
no vertical flip is needed), Z = 0 for the single MVP layer. Bricks are written in a
stable order (layer, row, column) so exports are reproducible and match step order.
"""
from __future__ import annotations

from typing import List

from .contracts import LDU_PER_STUD, Brick
from .palette import Palette

_IDENTITY = "1 0 0 0 1 0 0 0 1"

_HEADER = [
    "0 Mosaic Model",
    "0 Name: model.ldr",
    "0 Author: Bricky Model Generation System",
    "0 !LDRAW_ORG Unofficial_Model",
    "0 BFC CERTIFY CCW",
]


def sort_bricks(bricks: List[Brick]) -> List[Brick]:
    """Deterministic order: layer (Z=0 for MVP), then row (Y), then column (X)."""
    return sorted(bricks, key=lambda b: (0, b.y, b.x))


def export_ldr(bricks: List[Brick], palette: Palette) -> str:
    """Render the brick list as the text of a single .ldr file."""
    lines: List[str] = list(_HEADER)
    for brick in sort_bricks(bricks):
        color_id = palette.by_name(brick.color).ldraw
        x = brick.x * LDU_PER_STUD
        y = brick.y * LDU_PER_STUD
        z = 0
        lines.append(
            f"1 {color_id} {x} {y} {z} {_IDENTITY} {brick.part}.dat"
        )
    return "\n".join(lines) + "\n"
