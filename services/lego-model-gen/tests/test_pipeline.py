"""End-to-end pipeline tests with cross-artifact invariants."""
from __future__ import annotations

import json

from app import pipeline
from app.config import (
    ARTIFACT_LDR,
    ARTIFACT_META,
    ARTIFACT_PARTS,
    ARTIFACT_PDF,
    ARTIFACT_THUMBNAIL,
)
from app.storage import LocalArtifactStorage

from .conftest import make_config, two_band_image


def _run(tmp_path, grid=(32, 32)):
    storage = LocalArtifactStorage(str(tmp_path))
    config = make_config(grid[0], grid[1])
    result = pipeline.process(two_band_image(), config, storage)
    return storage, config, result


def test_all_artifacts_written(tmp_path):
    storage, config, _ = _run(tmp_path)
    for name in (
        ARTIFACT_LDR,
        ARTIFACT_PARTS,
        ARTIFACT_PDF,
        ARTIFACT_THUMBNAIL,
        ARTIFACT_META,
    ):
        path = storage.path(config.job_id, name)
        assert path.exists() and path.stat().st_size > 0


def test_progress_reaches_100(tmp_path):
    storage = LocalArtifactStorage(str(tmp_path))
    seen = []
    pipeline.process(
        two_band_image(), make_config(32, 32), storage, progress=seen.append
    )
    assert seen[-1] == 100
    assert seen == sorted(seen)  # monotonic


def test_brick_count_consistent_across_artifacts(tmp_path):
    storage, config, result = _run(tmp_path)

    ldr_text = storage.path(config.job_id, ARTIFACT_LDR).read_text()
    ldr_bricks = sum(1 for ln in ldr_text.splitlines() if ln.startswith("1 "))

    parts = json.loads(storage.path(config.job_id, ARTIFACT_PARTS).read_text())
    meta = json.loads(storage.path(config.job_id, ARTIFACT_META).read_text())

    assert result.meta.brick_count == ldr_bricks
    assert result.meta.brick_count == parts["total_parts"]
    assert result.meta.brick_count == meta["brick_count"]


def test_stud_count_full_for_opaque_image(tmp_path):
    _, _, result = _run(tmp_path, grid=(32, 32))
    assert result.meta.stud_count == 32 * 32


def test_meta_engine_version(tmp_path):
    _, _, result = _run(tmp_path)
    assert result.meta.engine_version == "1.0.0"


def test_result_urls_present(tmp_path):
    _, _, result = _run(tmp_path)
    assert set(result.urls) == {"ldr_url", "parts_url", "thumbnail_url", "pdf_url"}


def test_deterministic_ldr(tmp_path):
    s1, c1, _ = _run(tmp_path / "a")
    s2, c2, _ = _run(tmp_path / "b")
    assert (
        s1.path(c1.job_id, ARTIFACT_LDR).read_text()
        == s2.path(c2.job_id, ARTIFACT_LDR).read_text()
    )
