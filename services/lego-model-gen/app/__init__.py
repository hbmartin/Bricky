"""LEGO Model Generation System — deterministic 2D mosaic pipeline.

Public surface mirrors the pipeline contract:

    Job Config -> Color Grid -> Brick List -> {LDraw, Parts, Instructions}
"""
from __future__ import annotations

from .config import ENGINE_VERSION

__all__ = ["ENGINE_VERSION"]
