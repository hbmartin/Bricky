"""Perceptual color conversions: sRGB -> linear -> XYZ -> CIELAB, plus deltaE.

Vectorized with numpy. Averaging happens in linear RGB and nearest-color search in
CIELAB, per VISION_PIPELINE.md sec.4.3 / sec.5.2. CIEDE2000 is provided for accuracy;
CIE76 (Euclidean LAB) is the fast default used for grid quantization.
"""
from __future__ import annotations

import numpy as np

# D65 reference white (2 deg observer).
_XN, _YN, _ZN = 0.95047, 1.0, 1.08883

# sRGB -> linear XYZ matrix (IEC 61966-2-1, D65).
_RGB2XYZ = np.array(
    [
        [0.4124564, 0.3575761, 0.1804375],
        [0.2126729, 0.7151522, 0.0721750],
        [0.0193339, 0.1191920, 0.9503041],
    ]
)


def srgb_to_linear(srgb: np.ndarray) -> np.ndarray:
    """sRGB in [0,1] -> linear-light RGB in [0,1]."""
    srgb = np.asarray(srgb, dtype=np.float64)
    return np.where(srgb <= 0.04045, srgb / 12.92, ((srgb + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(linear: np.ndarray) -> np.ndarray:
    """Linear-light RGB in [0,1] -> sRGB in [0,1]."""
    linear = np.clip(np.asarray(linear, dtype=np.float64), 0.0, 1.0)
    return np.where(
        linear <= 0.0031308, linear * 12.92, 1.055 * (linear ** (1 / 2.4)) - 0.055
    )


def linear_rgb_to_xyz(linear: np.ndarray) -> np.ndarray:
    """Linear RGB (...,3) -> XYZ (...,3)."""
    return np.asarray(linear, dtype=np.float64) @ _RGB2XYZ.T


def _f(t: np.ndarray) -> np.ndarray:
    delta = 6.0 / 29.0
    return np.where(t > delta**3, np.cbrt(t), t / (3 * delta**2) + 4.0 / 29.0)


def xyz_to_lab(xyz: np.ndarray) -> np.ndarray:
    """XYZ (...,3) -> CIELAB (...,3)."""
    xyz = np.asarray(xyz, dtype=np.float64)
    fx = _f(xyz[..., 0] / _XN)
    fy = _f(xyz[..., 1] / _YN)
    fz = _f(xyz[..., 2] / _ZN)
    L = 116 * fy - 16
    a = 500 * (fx - fy)
    b = 200 * (fy - fz)
    return np.stack([L, a, b], axis=-1)


def srgb_to_lab(srgb: np.ndarray) -> np.ndarray:
    """sRGB in [0,1] (...,3) -> CIELAB (...,3)."""
    return xyz_to_lab(linear_rgb_to_xyz(srgb_to_linear(srgb)))


def delta_e_cie76(lab_a: np.ndarray, lab_b: np.ndarray) -> np.ndarray:
    """Euclidean CIE76 distance between LAB colors (broadcasts)."""
    diff = np.asarray(lab_a, dtype=np.float64) - np.asarray(lab_b, dtype=np.float64)
    return np.sqrt(np.sum(diff * diff, axis=-1))


def delta_e_ciede2000(lab1: np.ndarray, lab2: np.ndarray) -> np.ndarray:
    """CIEDE2000 color difference (broadcasts over leading dims)."""
    lab1 = np.asarray(lab1, dtype=np.float64)
    lab2 = np.asarray(lab2, dtype=np.float64)
    L1, a1, b1 = lab1[..., 0], lab1[..., 1], lab1[..., 2]
    L2, a2, b2 = lab2[..., 0], lab2[..., 1], lab2[..., 2]

    avg_Lp = (L1 + L2) / 2.0
    C1 = np.hypot(a1, b1)
    C2 = np.hypot(a2, b2)
    avg_C = (C1 + C2) / 2.0

    G = 0.5 * (1 - np.sqrt(avg_C**7 / (avg_C**7 + 25.0**7)))
    a1p = (1 + G) * a1
    a2p = (1 + G) * a2
    C1p = np.hypot(a1p, b1)
    C2p = np.hypot(a2p, b2)
    avg_Cp = (C1p + C2p) / 2.0

    h1p = np.degrees(np.arctan2(b1, a1p)) % 360
    h2p = np.degrees(np.arctan2(b2, a2p)) % 360

    dLp = L2 - L1
    dCp = C2p - C1p

    dhp = h2p - h1p
    dhp = np.where(dhp > 180, dhp - 360, dhp)
    dhp = np.where(dhp < -180, dhp + 360, dhp)
    dhp = np.where((C1p * C2p) == 0, 0.0, dhp)
    dHp = 2 * np.sqrt(C1p * C2p) * np.sin(np.radians(dhp) / 2.0)

    avg_hp = h1p + h2p
    hp_diff = np.abs(h1p - h2p)
    avg_hp = np.where(hp_diff > 180, (h1p + h2p + 360) / 2.0, (h1p + h2p) / 2.0)
    avg_hp = np.where((C1p * C2p) == 0, h1p + h2p, avg_hp)

    T = (
        1
        - 0.17 * np.cos(np.radians(avg_hp - 30))
        + 0.24 * np.cos(np.radians(2 * avg_hp))
        + 0.32 * np.cos(np.radians(3 * avg_hp + 6))
        - 0.20 * np.cos(np.radians(4 * avg_hp - 63))
    )
    d_ro = 30 * np.exp(-(((avg_hp - 275) / 25) ** 2))
    Rc = 2 * np.sqrt(avg_Cp**7 / (avg_Cp**7 + 25.0**7))
    Sl = 1 + (0.015 * (avg_Lp - 50) ** 2) / np.sqrt(20 + (avg_Lp - 50) ** 2)
    Sc = 1 + 0.045 * avg_Cp
    Sh = 1 + 0.015 * avg_Cp * T
    Rt = -np.sin(np.radians(2 * d_ro)) * Rc

    return np.sqrt(
        (dLp / Sl) ** 2
        + (dCp / Sc) ** 2
        + (dHp / Sh) ** 2
        + Rt * (dCp / Sc) * (dHp / Sh)
    )
