"""FastAPI app: async job workflow (API_DESIGN.md).

Endpoints:
- POST /jobs                 create a job from an uploaded image + config
- GET  /jobs/{id}            poll status/progress
- GET  /jobs/{id}/result     artifact URLs once done
- GET  /artifacts/{id}/{n}   serve a published artifact (local-storage MVP)
"""
from __future__ import annotations

import datetime as _dt
import os
import uuid
from typing import Optional

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse, JSONResponse

from .config import (
    ACCEPTED_IMAGE_TYPES,
    DEFAULT_GRID,
    DEFAULT_PALETTE_ID,
    MAX_UPLOAD_BYTES,
    snap_grid,
)
from .contracts import GridSize, JobConfig
from .jobs import STATUS_DONE, JobManager
from .palette import load_palette
from .storage import LocalArtifactStorage

_MEDIA_TYPES = {
    ".ldr": "text/plain",
    ".pdf": "application/pdf",
    ".json": "application/json",
    ".png": "image/png",
}


def _utc_now_iso() -> str:
    return _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def create_app(
    storage: Optional[LocalArtifactStorage] = None,
    manager: Optional[JobManager] = None,
) -> FastAPI:
    storage = storage or LocalArtifactStorage(
        os.environ.get("LEGO_ARTIFACT_DIR", "./_artifacts")
    )
    manager = manager or JobManager(storage)

    app = FastAPI(title="LEGO Model Generation System", version="1.0.0")

    @app.post("/jobs", status_code=202)
    async def create_job(
        image: UploadFile = File(...),
        width: int = Form(DEFAULT_GRID[0]),
        height: int = Form(DEFAULT_GRID[1]),
        palette: str = Form(DEFAULT_PALETTE_ID),
        background_removal: bool = Form(False),
    ) -> JSONResponse:
        if image.content_type not in ACCEPTED_IMAGE_TYPES:
            raise HTTPException(400, f"Unsupported image type: {image.content_type}")

        data = await image.read()
        if not data:
            raise HTTPException(400, "Empty image upload")
        if len(data) > MAX_UPLOAD_BYTES:
            raise HTTPException(413, "Image exceeds maximum upload size")

        try:
            load_palette(palette)
        except KeyError:
            raise HTTPException(400, f"Unknown palette: {palette}")

        grid_w, grid_h = snap_grid(width, height)
        job_id = uuid.uuid4().hex
        config = JobConfig(
            job_id=job_id,
            created_at=_utc_now_iso(),
            image_ref=f"upload://{job_id}/{image.filename or 'source'}",
            grid=GridSize(grid_w, grid_h),
            palette_id=palette,
            background_removal=background_removal,
        )
        manager.submit(data, config)
        return JSONResponse(
            status_code=202,
            content={
                "job_id": job_id,
                "status": "queued",
                "grid": {"width": grid_w, "height": grid_h},
            },
        )

    @app.get("/jobs/{job_id}")
    async def get_status(job_id: str):
        record = manager.get(job_id)
        if record is None:
            raise HTTPException(404, "Job not found")
        body = {"job_id": record.job_id, "status": record.status}
        if record.status not in (STATUS_DONE,):
            body["progress"] = record.progress
        if record.message:
            body["message"] = record.message
        return body

    @app.get("/jobs/{job_id}/result")
    async def get_result(job_id: str):
        record = manager.get(job_id)
        if record is None:
            raise HTTPException(404, "Job not found")
        if record.status != STATUS_DONE:
            raise HTTPException(409, f"Job not complete (status: {record.status})")
        return {"job_id": job_id, "status": record.status, **record.urls}

    @app.get("/artifacts/{job_id}/{name}")
    async def get_artifact(job_id: str, name: str):
        if "/" in name or ".." in name:
            raise HTTPException(400, "Invalid artifact name")
        path = storage.path(job_id, name)
        if not path.exists():
            raise HTTPException(404, "Artifact not found")
        media = _MEDIA_TYPES.get(path.suffix, "application/octet-stream")
        return FileResponse(path, media_type=media)

    app.state.storage = storage
    app.state.manager = manager
    return app


app = create_app()
