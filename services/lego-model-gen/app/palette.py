"""Palette loading and nearest-color quantization (DATA_CONTRACTS.md sec.6).

A palette is the single source of truth shared by quantization, LDraw export, and
the parts list. Numeric IDs come only from `data/colors.csv` (never hand-entered in
logic). Quantization maps an sRGB cell color to the perceptually nearest palette
color in CIELAB.
"""
from __future__ import annotations

import csv
import functools
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import numpy as np

from . import colorspace
from .config import DEFAULT_PALETTE_ID

_DATA_DIR = Path(__file__).resolve().parent / "data"


@dataclass(frozen=True)
class Color:
    name: str
    ldraw: int
    bricklink: int
    rebrickable: int
    rgb: Tuple[int, int, int]


class Palette:
    """An ordered, immutable set of LEGO colors with cached LAB coordinates."""

    def __init__(self, palette_id: str, colors: List[Color]):
        if not colors:
            raise ValueError("palette must contain at least one color")
        self.palette_id = palette_id
        self.colors = colors
        self._by_name: Dict[str, Color] = {c.name: c for c in colors}
        srgb = np.array([c.rgb for c in colors], dtype=np.float64) / 255.0
        self._lab = colorspace.srgb_to_lab(srgb)  # (N, 3)

    @property
    def names(self) -> List[str]:
        return [c.name for c in self.colors]

    def by_name(self, name: str) -> Color:
        try:
            return self._by_name[name]
        except KeyError as exc:
            raise KeyError(f"color '{name}' not in palette '{self.palette_id}'") from exc

    def __contains__(self, name: str) -> bool:
        return name in self._by_name

    def __len__(self) -> int:
        return len(self.colors)

    def nearest(self, srgb_color: Tuple[float, float, float]) -> str:
        """Return the palette color name nearest to a single sRGB [0,1] color."""
        names = self.quantize_grid(np.array([[srgb_color]], dtype=np.float64))
        return names[0][0]

    def quantize_grid(
        self, srgb_cells: np.ndarray, use_ciede2000: bool = False
    ) -> List[List[str]]:
        """Map an (H, W, 3) sRGB [0,1] array to a row-major grid of color names.

        CIE76 (Euclidean LAB) is the deterministic default; CIEDE2000 is available
        for higher perceptual accuracy at extra cost (VISION_PIPELINE.md sec.5.2).
        """
        srgb_cells = np.asarray(srgb_cells, dtype=np.float64)
        h, w, _ = srgb_cells.shape
        lab = colorspace.srgb_to_lab(srgb_cells).reshape(-1, 1, 3)  # (H*W, 1, 3)
        palette_lab = self._lab.reshape(1, -1, 3)  # (1, N, 3)

        if use_ciede2000:
            dist = colorspace.delta_e_ciede2000(lab, palette_lab)  # (H*W, N)
        else:
            dist = colorspace.delta_e_cie76(lab, palette_lab)  # (H*W, N)

        idx = np.argmin(dist, axis=1).reshape(h, w)
        names = self.names
        return [[names[idx[r, c]] for c in range(w)] for r in range(h)]


def _parse_color_row(row: Dict[str, str]) -> Color:
    hex_rgb = row["rgb"].strip().lstrip("#")
    rgb = (int(hex_rgb[0:2], 16), int(hex_rgb[2:4], 16), int(hex_rgb[4:6], 16))
    return Color(
        name=row["name"].strip(),
        ldraw=int(row["ldraw"]),
        bricklink=int(row["bricklink"]),
        rebrickable=int(row["rebrickable"]),
        rgb=rgb,
    )


def _csv_path(palette_id: str) -> Path:
    # The MVP ships one palette file; future palettes map to their own CSVs.
    if palette_id == DEFAULT_PALETTE_ID:
        return _DATA_DIR / "colors.csv"
    return _DATA_DIR / f"colors-{palette_id}.csv"


@functools.lru_cache(maxsize=None)
def load_palette(palette_id: str = DEFAULT_PALETTE_ID) -> Palette:
    """Load and cache a registered palette from its CSV (immutable once published)."""
    path = _csv_path(palette_id)
    if not path.exists():
        raise KeyError(f"unknown palette_id '{palette_id}' (no file {path.name})")
    colors: List[Color] = []
    with path.open(newline="", encoding="utf-8") as fh:
        reader = csv.DictReader(row for row in fh if not row.startswith("#"))
        for row in reader:
            colors.append(_parse_color_row(row))
    return Palette(palette_id, colors)
