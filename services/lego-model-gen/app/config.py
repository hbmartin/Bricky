"""Engine configuration: version, palette, grid presets, upload limits.

Centralizes the magic numbers from MVP_PLAN.md / VISION_PIPELINE.md so no other
module hard-codes them.
"""
from __future__ import annotations

from typing import List, Tuple

# Semver stamped onto every job and meta.json (DATA_CONTRACTS.md sec.9).
ENGINE_VERSION = "1.0.0"

# Default registered palette id (DATA_CONTRACTS.md sec.6).
DEFAULT_PALETTE_ID = "mvp-v1"

# Upload guardrails (API_DESIGN.md sec.6 / MVP_PLAN.md sec.5).
MAX_UPLOAD_BYTES = 20 * 1024 * 1024  # 20 MB
ACCEPTED_IMAGE_TYPES = ("image/png", "image/jpeg", "image/webp")

# Preprocessing: longest source dimension after normalization (VISION_PIPELINE sec.2.1).
MAX_SOURCE_DIM = 1024

# Grid bounds (VISION_PIPELINE.md sec.4.1).
MIN_GRID_DIM = 16
MAX_GRID_DIM = 96

# Supported grid presets (width, height) in studs (VISION_PIPELINE.md sec.4.1).
GRID_PRESETS: List[Tuple[int, int]] = [
    (32, 32),  # Small
    (48, 48),  # Medium (default)
    (64, 64),  # Large
    (48, 64),  # Portrait
    (64, 48),  # Landscape
]

DEFAULT_GRID: Tuple[int, int] = (48, 48)

# Flag raised when >= this fraction of cells quantize to one color
# (VISION_PIPELINE.md sec.5.4).
LOW_DETAIL_FRACTION = 0.95

# Artifact filenames (MVP_PLAN.md sec.6).
ARTIFACT_LDR = "model.ldr"
ARTIFACT_PDF = "instructions.pdf"
ARTIFACT_PARTS = "parts.json"
ARTIFACT_THUMBNAIL = "thumbnail.png"
ARTIFACT_META = "meta.json"


def snap_grid(width: int, height: int) -> Tuple[int, int]:
    """Snap a requested grid size to the nearest supported preset.

    Requests are first clamped to [MIN_GRID_DIM, MAX_GRID_DIM], then matched to the
    preset minimizing squared distance in (width, height). Ties resolve to the
    earlier preset for determinism.
    """
    w = max(MIN_GRID_DIM, min(MAX_GRID_DIM, int(width)))
    h = max(MIN_GRID_DIM, min(MAX_GRID_DIM, int(height)))

    def dist(preset: Tuple[int, int]) -> int:
        pw, ph = preset
        return (pw - w) ** 2 + (ph - h) ** 2

    return min(GRID_PRESETS, key=dist)
