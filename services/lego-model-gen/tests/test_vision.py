"""Tests for the vision pipeline."""
from __future__ import annotations

from app import vision

from .conftest import make_config, palette, solid_image, two_band_image


def test_grid_dimensions_match_config():
    grid = vision.build_color_grid(solid_image(), make_config(32, 32), palette())
    assert grid.width == 32 and grid.height == 32
    assert len(grid.cells) == 32 and len(grid.cells[0]) == 32


def test_solid_red_quantizes_to_bright_red():
    grid = vision.build_color_grid(solid_image(), make_config(32, 32), palette())
    assert all(c == "Bright Red" for row in grid.cells for c in row)


def test_solid_image_flags_low_detail():
    grid = vision.build_color_grid(solid_image(), make_config(32, 32), palette())
    assert "low_detail" in grid.warnings


def test_two_band_image_has_two_colors():
    grid = vision.build_color_grid(two_band_image(), make_config(32, 32), palette())
    distinct = {c for row in grid.cells for c in row}
    assert distinct == {"Bright Red", "Bright Blue"}
    assert "low_detail" not in grid.warnings


def test_background_removal_warns_when_requested():
    cfg = make_config(32, 32, background_removal=True)
    grid = vision.build_color_grid(solid_image(), cfg, palette())
    assert "background_removal_unavailable" in grid.warnings


def test_deterministic_output():
    img = two_band_image()
    a = vision.build_color_grid(img, make_config(48, 48), palette())
    b = vision.build_color_grid(img, make_config(48, 48), palette())
    assert a.cells == b.cells


def test_stud_count_full_for_opaque_image():
    grid = vision.build_color_grid(solid_image(), make_config(32, 32), palette())
    assert grid.stud_count() == 32 * 32
