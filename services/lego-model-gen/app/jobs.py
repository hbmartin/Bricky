"""In-process job orchestrator (LEGO_MODEL_GENERATION_SYSTEM.md sec.2.3).

Tracks job status/progress and runs the pipeline on a background thread pool. This is
the MVP stand-in for a Redis/RabbitMQ-backed worker; the public surface (submit, get)
is queue-agnostic so it can be swapped for a distributed queue later.
"""
from __future__ import annotations

import io
import threading
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from typing import Dict, Optional

from PIL import Image, UnidentifiedImageError

from . import pipeline
from .contracts import JobConfig
from .storage import ArtifactStorage

STATUS_QUEUED = "queued"
STATUS_PROCESSING = "processing"
STATUS_DONE = "done"
STATUS_ERROR = "error"


@dataclass
class JobRecord:
    job_id: str
    status: str = STATUS_QUEUED
    progress: int = 0
    message: Optional[str] = None
    urls: Dict[str, str] = field(default_factory=dict)


class JobManager:
    def __init__(self, storage: ArtifactStorage, max_workers: int = 2):
        self._storage = storage
        self._executor = ThreadPoolExecutor(max_workers=max_workers)
        self._records: Dict[str, JobRecord] = {}
        self._lock = threading.Lock()

    def submit(self, image_bytes: bytes, config: JobConfig) -> JobRecord:
        record = JobRecord(job_id=config.job_id)
        with self._lock:
            self._records[config.job_id] = record
        self._executor.submit(self._run, image_bytes, config)
        return record

    def get(self, job_id: str) -> Optional[JobRecord]:
        with self._lock:
            return self._records.get(job_id)

    def _update(self, job_id: str, **fields) -> None:
        with self._lock:
            record = self._records.get(job_id)
            if record is None:
                return
            for key, value in fields.items():
                setattr(record, key, value)

    def _run(self, image_bytes: bytes, config: JobConfig) -> None:
        job_id = config.job_id
        try:
            image = Image.open(io.BytesIO(image_bytes))
            image.load()
        except (UnidentifiedImageError, OSError):
            self._update(
                job_id, status=STATUS_ERROR, message="Invalid or unreadable image"
            )
            return

        self._update(job_id, status=STATUS_PROCESSING, progress=0)
        try:
            result = pipeline.process(
                image,
                config,
                self._storage,
                progress=lambda p: self._update(job_id, progress=p),
            )
        except Exception as exc:  # noqa: BLE001 - surface as job error, never crash worker
            self._update(job_id, status=STATUS_ERROR, message=str(exc))
            return

        self._update(
            job_id, status=STATUS_DONE, progress=100, urls=result.urls
        )

    def shutdown(self) -> None:
        self._executor.shutdown(wait=True)
