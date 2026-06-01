"""Brick packing v1: row-based run-length tiling (BRICK_PACKING.md).

For each row, consecutive same-color non-null cells form a run; each run is split
into plates greedily, longest-allowed-first. Output is deterministic (rows top to
bottom, columns left to right) and satisfies the Brick List invariants:
full coverage, no overlap, color fidelity, part<->length consistency.
"""
from __future__ import annotations

from typing import List

from .contracts import ALLOWED_LENGTHS, Brick, ColorGrid


def _split_run(length: int) -> List[int]:
    """Greedy longest-first split of a run length into allowed plate lengths."""
    pieces: List[int] = []
    remaining = length
    while remaining > 0:
        for size in ALLOWED_LENGTHS:  # descending
            if size <= remaining:
                pieces.append(size)
                remaining -= size
                break
    return pieces


def pack(grid: ColorGrid) -> List[Brick]:
    """Pack a color grid into an ordered list of plate bricks."""
    bricks: List[Brick] = []
    for y in range(grid.height):
        row = grid.cells[y]
        x = 0
        while x < grid.width:
            color = row[x]
            if color is None:
                x += 1
                continue
            # Extend the run while color matches.
            run_start = x
            while x < grid.width and row[x] == color:
                x += 1
            run_len = x - run_start
            offset = run_start
            for piece in _split_run(run_len):
                bricks.append(Brick(x=offset, y=y, length=piece, color=color))
                offset += piece
    return bricks
