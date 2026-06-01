"""Vision pipeline: input image -> stud-aligned LEGO color grid (VISION_PIPELINE.md).

Steps: normalize -> cover-fit to grid -> linear-light area average per cell ->
perceptual quantization to the palette. Deterministic given the same image + config.
Background removal is not shipped in the MVP worker; when requested, the cell colors
are computed full-frame and a `background_removal_unavailable` warning is raised so
the client can surface it honestly (no silent fake silhouette).
"""
from __future__ import annotations

from typing import List, Optional

import numpy as np
from PIL import Image, ImageOps

from . import colorspace
from .config import LOW_DETAIL_FRACTION, MAX_SOURCE_DIM
from .contracts import ColorGrid, JobConfig
from .palette import Palette, load_palette

# Per-cell supersampling cap for the linear-light average.
_MAX_SAMPLES_PER_CELL = 8


def preprocess(image: Image.Image) -> Image.Image:
    """Normalize orientation, convert to RGB, and bound the longest dimension."""
    image = ImageOps.exif_transpose(image)
    if image.mode != "RGB":
        image = image.convert("RGB")
    w, h = image.size
    longest = max(w, h)
    if longest > MAX_SOURCE_DIM:
        scale = MAX_SOURCE_DIM / longest
        image = image.resize(
            (max(1, round(w * scale)), max(1, round(h * scale))), Image.LANCZOS
        )
    return image


def _cover_fit_crop(image: Image.Image, grid_w: int, grid_h: int) -> Image.Image:
    """Center-crop the image so it matches the grid aspect ratio (no letterbox)."""
    w, h = image.size
    target_aspect = grid_w / grid_h
    src_aspect = w / h
    if src_aspect > target_aspect:
        # Source is wider: crop width.
        new_w = round(h * target_aspect)
        left = (w - new_w) // 2
        box = (left, 0, left + new_w, h)
    else:
        # Source is taller: crop height.
        new_h = round(w / target_aspect)
        top = (h - new_h) // 2
        box = (0, top, w, top + new_h)
    return image.crop(box)


def _cell_colors_srgb(image: Image.Image, grid_w: int, grid_h: int) -> np.ndarray:
    """Return an (grid_h, grid_w, 3) sRGB [0,1] array, averaged in linear light.

    The cover-fit crop is resampled to an integer multiple of the grid, then each
    cell's SxS block is averaged in linear RGB and converted back to sRGB.
    """
    crop = _cover_fit_crop(image, grid_w, grid_h)
    cw, ch = crop.size
    samples = max(1, min(_MAX_SAMPLES_PER_CELL, round(min(cw / grid_w, ch / grid_h))))
    resized = crop.resize((grid_w * samples, grid_h * samples), Image.LANCZOS)

    srgb = np.asarray(resized, dtype=np.float64) / 255.0  # (gh*s, gw*s, 3)
    linear = colorspace.srgb_to_linear(srgb)
    blocks = linear.reshape(grid_h, samples, grid_w, samples, 3)
    cell_linear = blocks.mean(axis=(1, 3))  # (gh, gw, 3)
    return colorspace.linear_to_srgb(cell_linear)


def build_color_grid(
    image: Image.Image, config: JobConfig, palette: Optional[Palette] = None
) -> ColorGrid:
    """Run the full vision pipeline and return the quantized color grid."""
    palette = palette or load_palette(config.palette_id)
    grid_w, grid_h = config.grid.width, config.grid.height

    normalized = preprocess(image)
    cell_srgb = _cell_colors_srgb(normalized, grid_w, grid_h)
    names = palette.quantize_grid(cell_srgb, use_ciede2000=False)

    cells: List[List[Optional[str]]] = [list(row) for row in names]
    warnings: List[str] = []

    if config.background_removal:
        warnings.append("background_removal_unavailable")

    if _dominant_fraction(names) >= LOW_DETAIL_FRACTION:
        warnings.append("low_detail")

    return ColorGrid(
        width=grid_w,
        height=grid_h,
        palette_id=palette.palette_id,
        cells=cells,
        warnings=warnings,
    )


def _dominant_fraction(names: List[List[str]]) -> float:
    counts: dict = {}
    total = 0
    for row in names:
        for name in row:
            if name is None:
                continue
            counts[name] = counts.get(name, 0) + 1
            total += 1
    if total == 0:
        return 0.0
    return max(counts.values()) / total
