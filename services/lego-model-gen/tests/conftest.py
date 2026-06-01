"""Shared test fixtures and helpers."""
from __future__ import annotations

import datetime as _dt
import io
from typing import List, Optional

from PIL import Image

from app.contracts import ColorGrid, GridSize, JobConfig
from app.palette import load_palette


def make_config(
    width: int = 32,
    height: int = 32,
    palette_id: str = "mvp-v1",
    background_removal: bool = False,
    job_id: str = "test-job",
) -> JobConfig:
    return JobConfig(
        job_id=job_id,
        created_at=_dt.datetime(2026, 5, 31, tzinfo=_dt.timezone.utc).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        ),
        image_ref="upload://test/source.png",
        grid=GridSize(width, height),
        palette_id=palette_id,
        background_removal=background_removal,
    )


def solid_image(rgb=(201, 26, 9), size=(128, 128)) -> Image.Image:
    """A solid-color image (defaults to Bright Red C91A09)."""
    return Image.new("RGB", size, rgb)


def two_band_image(top=(201, 26, 9), bottom=(0, 85, 191), size=(128, 128)) -> Image.Image:
    """Top half / bottom half image (defaults Bright Red / Bright Blue)."""
    img = Image.new("RGB", size)
    w, h = size
    img.paste(top, (0, 0, w, h // 2))
    img.paste(bottom, (0, h // 2, w, h))
    return img


def png_bytes(image: Image.Image) -> bytes:
    buf = io.BytesIO()
    image.save(buf, format="PNG")
    return buf.getvalue()


def grid_from_rows(rows: List[List[Optional[str]]], palette_id: str = "mvp-v1") -> ColorGrid:
    """Build a ColorGrid from explicit color-name rows (None = omitted)."""
    height = len(rows)
    width = len(rows[0]) if rows else 0
    return ColorGrid(width=width, height=height, palette_id=palette_id, cells=rows)


def palette():
    return load_palette("mvp-v1")
