"""Worker pipeline: image + JobConfig -> published artifacts (MVP_PLAN.md sec.4).

Orchestrates vision -> packing -> LDraw -> parts -> instructions -> meta, writing the
five artifacts (model.ldr, instructions.pdf, parts.json, thumbnail.png, meta.json) to
storage. A progress callback (0-100) is invoked per stage for the polling API.
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Callable, Dict, List, Optional

from PIL import Image

from . import instructions, ldraw, packing, parts, vision
from .config import (
    ARTIFACT_LDR,
    ARTIFACT_META,
    ARTIFACT_PARTS,
    ARTIFACT_PDF,
    ARTIFACT_THUMBNAIL,
    ENGINE_VERSION,
)
from .contracts import GridSize, JobConfig, JobMeta
from .palette import load_palette
from .storage import ArtifactStorage

ProgressCallback = Callable[[int], None]


@dataclass
class JobResult:
    meta: JobMeta
    urls: Dict[str, str]


def _noop(_: int) -> None:
    pass


def process(
    image: Image.Image,
    config: JobConfig,
    storage: ArtifactStorage,
    progress: Optional[ProgressCallback] = None,
) -> JobResult:
    """Run the full deterministic pipeline and publish all artifacts."""
    report = progress or _noop
    palette = load_palette(config.palette_id)

    report(10)
    grid = vision.build_color_grid(image, config, palette=palette)

    report(35)
    bricks = packing.pack(grid)

    report(55)
    ldr_text = ldraw.export_ldr(bricks, palette)

    report(70)
    parts_list = parts.aggregate(bricks, palette)

    report(85)
    thumbnail_png = instructions.render_thumbnail(grid, palette)
    pdf_bytes = instructions.build_instructions_pdf(
        grid, parts_list, palette, brick_count=len(bricks)
    )

    meta = JobMeta(
        job_id=config.job_id,
        grid=GridSize(grid.width, grid.height),
        palette_id=palette.palette_id,
        brick_count=len(bricks),
        stud_count=grid.stud_count(),
        warnings=list(grid.warnings),
        engine_version=ENGINE_VERSION,
    )

    urls = {
        "ldr_url": storage.write(config.job_id, ARTIFACT_LDR, ldr_text.encode("utf-8")),
        "parts_url": storage.write(
            config.job_id,
            ARTIFACT_PARTS,
            json.dumps(parts.parts_to_dict(parts_list), indent=2).encode("utf-8"),
        ),
        "thumbnail_url": storage.write(config.job_id, ARTIFACT_THUMBNAIL, thumbnail_png),
        "pdf_url": storage.write(config.job_id, ARTIFACT_PDF, pdf_bytes),
    }
    storage.write(
        config.job_id,
        ARTIFACT_META,
        json.dumps(_meta_to_dict(meta), indent=2).encode("utf-8"),
    )

    report(100)
    return JobResult(meta=meta, urls=urls)


def _meta_to_dict(meta: JobMeta) -> dict:
    return {
        "job_id": meta.job_id,
        "grid": {"width": meta.grid.width, "height": meta.grid.height},
        "palette_id": meta.palette_id,
        "brick_count": meta.brick_count,
        "stud_count": meta.stud_count,
        "warnings": list(meta.warnings),
        "engine_version": meta.engine_version,
    }


__all__: List[str] = ["process", "JobResult"]
