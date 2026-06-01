"""Tests for palette loading and quantization."""
from __future__ import annotations

import numpy as np
import pytest

from app.palette import load_palette


def test_load_default_palette():
    pal = load_palette("mvp-v1")
    assert len(pal) >= 10
    assert "Bright Red" in pal
    assert "Black" in pal


def test_unknown_palette_raises():
    with pytest.raises(KeyError):
        load_palette("does-not-exist")


def test_color_ids_resolved_from_csv():
    pal = load_palette("mvp-v1")
    red = pal.by_name("Bright Red")
    # Canonical Bright Red IDs (PARTS_INVENTORY.md sec.3.1 corrected mapping).
    assert red.ldraw == 4
    assert red.bricklink == 5
    assert red.rebrickable == 4


def test_nearest_exact_match():
    pal = load_palette("mvp-v1")
    red = pal.by_name("Bright Red")
    srgb = tuple(v / 255.0 for v in red.rgb)
    assert pal.nearest(srgb) == "Bright Red"


def test_nearest_pure_black_white():
    pal = load_palette("mvp-v1")
    assert pal.nearest((0.0, 0.0, 0.0)) == "Black"
    assert pal.nearest((1.0, 1.0, 1.0)) == "White"


def test_quantize_grid_shape_and_names():
    pal = load_palette("mvp-v1")
    cells = np.zeros((3, 4, 3), dtype=np.float64)  # all black
    names = pal.quantize_grid(cells)
    assert len(names) == 3 and len(names[0]) == 4
    assert all(n == "Black" for row in names for n in row)


def test_quantize_deterministic():
    pal = load_palette("mvp-v1")
    cells = np.random.default_rng(7).random((5, 5, 3))
    assert pal.quantize_grid(cells) == pal.quantize_grid(cells)
