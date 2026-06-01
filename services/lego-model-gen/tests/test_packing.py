"""Tests for brick packing invariants."""
from __future__ import annotations

from app.contracts import ALLOWED_LENGTHS, PART_BY_LENGTH
from app.packing import _split_run, pack

from .conftest import grid_from_rows


def test_split_run_greedy_longest_first():
    assert _split_run(4) == [4]
    assert _split_run(5) == [4, 1]
    assert _split_run(7) == [4, 3]
    assert _split_run(10) == [4, 4, 2]
    assert _split_run(1) == [1]


def test_split_run_sums_to_length():
    for n in range(1, 50):
        assert sum(_split_run(n)) == n


def test_split_run_only_allowed_lengths():
    for n in range(1, 50):
        assert all(p in ALLOWED_LENGTHS for p in _split_run(n))


def test_pack_full_coverage():
    rows = [["Bright Red"] * 7, ["Bright Blue"] * 7]
    grid = grid_from_rows(rows)
    bricks = pack(grid)
    assert sum(b.length for b in bricks) == grid.stud_count()


def test_pack_skips_none_cells():
    rows = [["Bright Red", None, "Bright Red", "Bright Red"]]
    grid = grid_from_rows(rows)
    bricks = pack(grid)
    # 1 + (2-run) => 1x1 then 1x2 = 2 bricks, total length 3.
    assert sum(b.length for b in bricks) == 3
    assert all(b.color == "Bright Red" for b in bricks)


def test_pack_no_overlap():
    rows = [["Bright Red"] * 10, ["Bright Yellow"] * 10]
    bricks = pack(grid_from_rows(rows))
    occupied = set()
    for b in bricks:
        for dx in range(b.length):
            cell = (b.x + dx, b.y)
            assert cell not in occupied
            occupied.add(cell)
    assert len(occupied) == 20


def test_pack_color_runs_break_bricks():
    rows = [["Bright Red", "Bright Red", "Bright Blue", "Bright Blue"]]
    bricks = pack(grid_from_rows(rows))
    assert len(bricks) == 2
    assert {b.color for b in bricks} == {"Bright Red", "Bright Blue"}


def test_part_length_consistency():
    rows = [["Black"] * 9]
    for b in pack(grid_from_rows(rows)):
        assert b.part == PART_BY_LENGTH[b.length]


def test_pack_deterministic():
    rows = [["Tan", "Tan", None, "Black", "Black", "Black", "Black", "Black"]]
    grid = grid_from_rows(rows)
    assert pack(grid) == pack(grid)
