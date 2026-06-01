"""Golden-file regression tests (MVP_PLAN.md sec.8).

A fixed synthetic input image drives the full deterministic pipeline; the resulting
grid, brick list, parts list, and LDraw text are compared byte-for-byte against
checked-in golden files. CI fails on any diff, locking in determinism (Success
Criteria #3) and cross-artifact consistency (#2).

Regenerate intentionally with:  GOLDEN_REGEN=1 pytest tests/test_golden.py
"""
from __future__ import annotations

import json
import os
from pathlib import Path

from app import ldraw, packing, parts, vision

from .conftest import fixture_image, make_config, palette

_GOLDEN_DIR = Path(__file__).resolve().parent / "golden"
_GRID = (32, 32)
_REGEN = os.environ.get("GOLDEN_REGEN") == "1"


def _build_artifacts():
    pal = palette()
    grid = vision.build_color_grid(fixture_image(), make_config(*_GRID), pal)
    bricks = packing.pack(grid)
    parts_dict = parts.parts_to_dict(parts.aggregate(bricks, pal))
    ldr_text = ldraw.export_ldr(bricks, pal)
    bricks_list = [
        {"x": b.x, "y": b.y, "length": b.length, "color": b.color, "part": b.part}
        for b in bricks
    ]
    return {
        "grid.json": {
            "width": grid.width,
            "height": grid.height,
            "palette_id": grid.palette_id,
            "warnings": grid.warnings,
            "cells": grid.cells,
        },
        "bricks.json": bricks_list,
        "parts.json": parts_dict,
        "model.ldr": ldr_text,
    }


def _read_golden(name: str) -> str:
    return (_GOLDEN_DIR / name).read_text()


def _serialize(name: str, value) -> str:
    if name.endswith(".json"):
        return json.dumps(value, indent=2, ensure_ascii=False) + "\n"
    return value


def _regenerate(artifacts) -> None:
    _GOLDEN_DIR.mkdir(parents=True, exist_ok=True)
    for name, value in artifacts.items():
        (_GOLDEN_DIR / name).write_text(_serialize(name, value))


_ARTIFACTS = _build_artifacts()

if _REGEN:  # pragma: no cover - manual maintenance path
    _regenerate(_ARTIFACTS)


def test_grid_matches_golden():
    assert _serialize("grid.json", _ARTIFACTS["grid.json"]) == _read_golden("grid.json")


def test_bricks_match_golden():
    assert _serialize("bricks.json", _ARTIFACTS["bricks.json"]) == _read_golden(
        "bricks.json"
    )


def test_parts_match_golden():
    assert _serialize("parts.json", _ARTIFACTS["parts.json"]) == _read_golden(
        "parts.json"
    )


def test_ldr_matches_golden():
    assert _ARTIFACTS["model.ldr"] == _read_golden("model.ldr")


def test_cross_artifact_brick_count_in_golden():
    bricks = json.loads(_read_golden("bricks.json"))
    parts_json = json.loads(_read_golden("parts.json"))
    ldr_lines = [
        ln for ln in _read_golden("model.ldr").splitlines() if ln.startswith("1 ")
    ]
    assert len(bricks) == parts_json["total_parts"] == len(ldr_lines)


def test_pipeline_is_deterministic_against_golden():
    # Rebuilding from scratch must reproduce the same bytes.
    rebuilt = _build_artifacts()
    assert _serialize("grid.json", rebuilt["grid.json"]) == _read_golden("grid.json")
    assert rebuilt["model.ldr"] == _read_golden("model.ldr")
