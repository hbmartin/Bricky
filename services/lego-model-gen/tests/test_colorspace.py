"""Tests for color-space conversions and deltaE."""
from __future__ import annotations

import numpy as np

from app import colorspace


def test_srgb_linear_roundtrip():
    srgb = np.random.default_rng(0).random((10, 3))
    back = colorspace.linear_to_srgb(colorspace.srgb_to_linear(srgb))
    assert np.allclose(srgb, back, atol=1e-9)


def test_known_lab_anchors():
    # White, black, and mid gray have well-known L* values.
    lab = colorspace.srgb_to_lab(np.array([[1.0, 1.0, 1.0]]))
    assert np.allclose(lab[0], [100.0, 0.0, 0.0], atol=1e-3)

    lab_black = colorspace.srgb_to_lab(np.array([[0.0, 0.0, 0.0]]))
    assert np.allclose(lab_black[0], [0.0, 0.0, 0.0], atol=1e-6)


def test_red_is_positive_a():
    lab = colorspace.srgb_to_lab(np.array([[1.0, 0.0, 0.0]]))
    assert lab[0, 1] > 50  # strong red -> large +a*


def test_cie76_zero_for_identical():
    lab = colorspace.srgb_to_lab(np.array([[0.3, 0.6, 0.2]]))
    assert colorspace.delta_e_cie76(lab, lab)[0] == 0.0


def test_ciede2000_zero_for_identical():
    lab = colorspace.srgb_to_lab(np.array([[0.3, 0.6, 0.2]]))
    assert colorspace.delta_e_ciede2000(lab, lab)[0] < 1e-9


def test_ciede2000_positive_for_distinct():
    a = colorspace.srgb_to_lab(np.array([[1.0, 0.0, 0.0]]))
    b = colorspace.srgb_to_lab(np.array([[0.0, 0.0, 1.0]]))
    assert colorspace.delta_e_ciede2000(a, b)[0] > 10


def test_cie76_broadcasts():
    a = colorspace.srgb_to_lab(np.random.default_rng(1).random((5, 1, 3)))
    b = colorspace.srgb_to_lab(np.random.default_rng(2).random((1, 4, 3)))
    dist = colorspace.delta_e_cie76(a, b)
    assert dist.shape == (5, 4)
