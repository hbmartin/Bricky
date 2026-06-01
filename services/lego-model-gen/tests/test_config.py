"""Tests for grid presets / snap_grid."""
from __future__ import annotations

from app.config import GRID_PRESETS, MAX_GRID_DIM, MIN_GRID_DIM, snap_grid


def test_exact_presets_snap_to_themselves():
    for preset in GRID_PRESETS:
        assert snap_grid(*preset) == preset


def test_default_medium():
    assert snap_grid(48, 48) == (48, 48)


def test_clamps_below_minimum():
    # Tiny request clamps up then snaps to the nearest (smallest) preset.
    assert snap_grid(2, 2) == (32, 32)


def test_clamps_above_maximum():
    assert snap_grid(500, 500) == (64, 64)


def test_nearest_preset_by_distance():
    # 50x50 is closest to the 48x48 preset.
    assert snap_grid(50, 50) == (48, 48)
    # 60x44 is closest to landscape 64x48.
    assert snap_grid(60, 44) == (64, 48)


def test_result_is_a_registered_preset():
    assert snap_grid(40, 70) in GRID_PRESETS


def test_clamp_bounds_constants():
    assert MIN_GRID_DIM < MAX_GRID_DIM
