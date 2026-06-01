"""Shared data contracts (DATA_CONTRACTS.md).

These dataclasses are the single source of truth for data flowing between stages:

    JobConfig -> ColorGrid -> [Brick] -> {LDraw, PartsList, JobMeta}

`length -> part` is pinned by the Part Contract (DATA_CONTRACTS.md sec.7); the MVP
packer emits only 1x1..1x4 plates.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, List, Optional

# Part Contract (DATA_CONTRACTS.md sec.7): plate length in studs -> LDraw part id.
PART_BY_LENGTH: Dict[int, str] = {1: "3024", 2: "3023", 3: "3623", 4: "3710"}

# Lengths the MVP packer may emit, greedy longest-first.
ALLOWED_LENGTHS: List[int] = [4, 3, 2, 1]

# LDraw scaling (LDRAW_EXPORT.md sec.2): 1 stud = 20 LDU.
LDU_PER_STUD = 20


def part_for_length(length: int) -> str:
    """Return the LDraw part id for a plate run length, enforcing the contract."""
    try:
        return PART_BY_LENGTH[length]
    except KeyError as exc:  # pragma: no cover - guards programmer error
        raise ValueError(f"unsupported plate length: {length}") from exc


@dataclass(frozen=True)
class GridSize:
    width: int
    height: int


@dataclass(frozen=True)
class JobConfig:
    """Produced by the API from the upload request; consumed by the worker."""

    job_id: str
    created_at: str  # ISO-8601 UTC
    image_ref: str
    grid: GridSize
    palette_id: str
    background_removal: bool = False
    dither: bool = False


@dataclass
class ColorGrid:
    """Output of the vision pipeline; sole input to brick packing.

    `cells` is row-major: len(cells) == height, len(cells[r]) == width. Each entry
    is a palette color name or None (omitted/background stud).
    """

    width: int
    height: int
    palette_id: str
    cells: List[List[Optional[str]]]
    warnings: List[str] = field(default_factory=list)

    def stud_count(self) -> int:
        return sum(1 for row in self.cells for c in row if c is not None)


@dataclass(frozen=True)
class Brick:
    """A placed plate run. (x, y) is the left-most stud; length runs along +X."""

    x: int
    y: int
    length: int
    color: str

    @property
    def part(self) -> str:
        return part_for_length(self.length)


@dataclass(frozen=True)
class PartLine:
    part: str
    color: str
    qty: int
    ldraw_color: int
    bricklink_color: int
    rebrickable_color: int


@dataclass
class PartsList:
    palette_id: str
    parts: List[PartLine]
    total_parts: int


@dataclass
class JobMeta:
    job_id: str
    grid: GridSize
    palette_id: str
    brick_count: int
    stud_count: int
    warnings: List[str]
    engine_version: str
