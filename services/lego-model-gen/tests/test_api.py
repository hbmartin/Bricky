"""API tests using FastAPI's TestClient."""
from __future__ import annotations

import time

import pytest
from fastapi.testclient import TestClient

from app.api import create_app
from app.jobs import JobManager
from app.storage import LocalArtifactStorage

from .conftest import png_bytes, two_band_image


@pytest.fixture
def client(tmp_path):
    storage = LocalArtifactStorage(str(tmp_path))
    manager = JobManager(storage, max_workers=1)
    app = create_app(storage=storage, manager=manager)
    with TestClient(app) as c:
        yield c
    manager.shutdown()


def _poll_until_done(client, job_id, timeout=30.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        resp = client.get(f"/jobs/{job_id}")
        assert resp.status_code == 200
        status = resp.json()["status"]
        if status in ("done", "error"):
            return resp.json()
        time.sleep(0.1)
    raise AssertionError("job did not finish in time")


def _create_job(client, width=32, height=32):
    files = {"image": ("source.png", png_bytes(two_band_image()), "image/png")}
    data = {"width": str(width), "height": str(height)}
    return client.post("/jobs", files=files, data=data)


def test_create_job_accepted(client):
    resp = _create_job(client)
    assert resp.status_code == 202
    body = resp.json()
    assert body["status"] == "queued"
    assert body["grid"] == {"width": 32, "height": 32}
    assert "job_id" in body


def test_full_workflow_to_result(client):
    job_id = _create_job(client).json()["job_id"]
    final = _poll_until_done(client, job_id)
    assert final["status"] == "done"

    result = client.get(f"/jobs/{job_id}/result")
    assert result.status_code == 200
    urls = result.json()
    for key in ("ldr_url", "parts_url", "thumbnail_url", "pdf_url"):
        assert key in urls


def test_artifact_download(client):
    job_id = _create_job(client).json()["job_id"]
    _poll_until_done(client, job_id)
    urls = client.get(f"/jobs/{job_id}/result").json()

    ldr = client.get(urls["ldr_url"])
    assert ldr.status_code == 200
    assert ldr.text.startswith("0 Mosaic Model")

    parts = client.get(urls["parts_url"])
    assert parts.status_code == 200
    assert parts.json()["palette_id"] == "mvp-v1"


def test_grid_snapped_on_create(client):
    resp = _create_job(client, width=50, height=50)
    assert resp.json()["grid"] == {"width": 48, "height": 48}


def test_rejects_unsupported_type(client):
    files = {"image": ("bad.txt", b"not an image", "text/plain")}
    resp = client.post("/jobs", files=files)
    assert resp.status_code == 400


def test_rejects_unknown_palette(client):
    files = {"image": ("source.png", png_bytes(two_band_image()), "image/png")}
    resp = client.post("/jobs", files=files, data={"palette": "nope"})
    assert resp.status_code == 400


def test_result_conflict_before_done(client):
    # A freshly created job is not yet done; result should 409 (or already done).
    job_id = _create_job(client).json()["job_id"]
    resp = client.get(f"/jobs/{job_id}/result")
    assert resp.status_code in (200, 409)


def test_unknown_job_404(client):
    assert client.get("/jobs/does-not-exist").status_code == 404
    assert client.get("/jobs/does-not-exist/result").status_code == 404
