"""Artifact storage abstraction (LEGO_MODEL_GENERATION_SYSTEM.md sec.8).

The MVP uses local-filesystem storage namespaced by job_id; the interface mirrors an
S3/CDN layout so it can be swapped for object storage later. Writes are
write-then-publish (temp file + atomic replace) so failed jobs never leave partial
artifacts.
"""
from __future__ import annotations

import os
from pathlib import Path
from typing import Protocol


class ArtifactStorage(Protocol):
    def write(self, job_id: str, name: str, data: bytes) -> str: ...
    def url(self, job_id: str, name: str) -> str: ...
    def path(self, job_id: str, name: str) -> Path: ...
    def exists(self, job_id: str, name: str) -> bool: ...


class LocalArtifactStorage:
    """Stores artifacts under `base_dir/<job_id>/<name>` and serves relative URLs."""

    def __init__(self, base_dir: str, url_prefix: str = "/artifacts"):
        self.base_dir = Path(base_dir)
        self.url_prefix = url_prefix.rstrip("/")
        self.base_dir.mkdir(parents=True, exist_ok=True)

    def path(self, job_id: str, name: str) -> Path:
        return self.base_dir / job_id / name

    def write(self, job_id: str, name: str, data: bytes) -> str:
        dest = self.path(job_id, name)
        dest.parent.mkdir(parents=True, exist_ok=True)
        tmp = dest.with_suffix(dest.suffix + ".tmp")
        tmp.write_bytes(data)
        os.replace(tmp, dest)  # atomic publish
        return self.url(job_id, name)

    def url(self, job_id: str, name: str) -> str:
        return f"{self.url_prefix}/{job_id}/{name}"

    def exists(self, job_id: str, name: str) -> bool:
        return self.path(job_id, name).exists()
