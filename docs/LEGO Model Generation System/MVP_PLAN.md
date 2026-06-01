# MVP Plan

This document defines the Minimum Viable Product (MVP) for the LEGO mosaic generation system. The MVP focuses on a clean, reliable 2D pipeline that converts an uploaded image into a LEGO mosaic with instructions and a parts list.

---

## 1. MVP Goals

The MVP must deliver:

- A working 2D mosaic generator
- A mobile‑friendly API
- A complete artifact set:
  - LDraw file
  - Instructions PDF
  - Parts list JSON
  - Thumbnail image
- A stable, predictable user experience

The MVP does NOT include 3D reconstruction, advanced brick packing, or marketplace integration.

---

## 2. MVP Scope

### Included

- Image upload
- Image preprocessing
- Grid projection
- LEGO color quantization
- Simple row‑based brick packing
- LDraw export (identity orientation only)
- Basic instruction generation (row‑by‑row)
- Parts counting and mapping
- Job queue and worker
- CDN‑served artifacts

### Excluded (Future)

- Background removal
- Height‑map / low‑relief builds
- 3D scanning
- Cost optimization
- BrickLink/Rebrickable integration
- User accounts
- WebSockets
- Inventory‑aware optimization

---

## 3. MVP Architecture

The MVP uses a simple, scalable architecture:

- API Gateway (FastAPI or Node)
- Job Queue (Redis or RabbitMQ)
- Worker (Python)
- Object Storage (S3‑compatible)
- CDN for artifact delivery

The worker performs all heavy processing.

---

## 4. MVP Processing Pipeline

### Step 1 — Preprocess Image

- Convert to RGB
- Resize to max dimension (e.g., 1024 px)
- Normalize orientation

### Step 2 — Grid Projection

- Map image to W × H grid
- Compute average color per cell

### Step 3 — Color Quantization

- Convert RGB to LAB
- Find nearest LEGO color

### Step 4 — Brick Packing (Simple)

- Row‑based packing
- Allowed parts: 1×4, 1×2, 1×1
- No stability or cost optimization

### Step 5 — LDraw Export

- Identity orientation
- One .ldr file
- No submodels

### Step 6 — Instruction Generation

- Row‑by‑row steps
- Top‑down orthographic render
- Simple PDF assembly

### Step 7 — Parts List

- Count bricks by part and color
- Map to LDraw/BrickLink/Rebrickable IDs

---

## 5. MVP API

The full contract lives in API_DESIGN.md; the MVP surface is the minimum subset
below.

### POST /jobs

- Accept `multipart/form-data`: `image` (required), `width`, `height`, `palette`,
  `background_removal`.
- Validate file type and size (≤ 20 MB) before enqueuing.
- Snap `width`/`height` to a supported grid preset (see VISION_PIPELINE.md §4.1).
- Return `{ job_id, status: "queued" }`.

### GET /jobs/{id}

- Return `{ job_id, status, progress }`.
- `status ∈ { queued, processing, done, error }`.

### GET /jobs/{id}/result

- Return artifact URLs once `status == done`:
  `ldr_url`, `pdf_url`, `parts_url`, `thumbnail_url`.

---

## 6. MVP Deliverables

For every successful job the worker produces and uploads:

| Artifact            | File                | Source doc               |
| ------------------- | ------------------- | ------------------------ |
| LDraw model         | `model.ldr`         | LDRAW_EXPORT.md          |
| Instructions PDF    | `instructions.pdf`  | INSTRUCTIONS_GENERATOR.md |
| Parts list          | `parts.json`        | PARTS_INVENTORY.md       |
| Thumbnail           | `thumbnail.png`     | INSTRUCTIONS_GENERATOR.md |
| Job metadata        | `meta.json`         | DATA_CONTRACTS.md        |

`meta.json` records the resolved grid size, palette id, brick count, and warning
flags (`low_detail`, etc.) so the client can render an accurate summary.

---

## 7. Success Criteria

The MVP is considered done when **all** of the following hold:

1. **Correctness** — A 48×48 photo upload returns a `model.ldr` that loads without
   errors in LeoCAD/LDView, with stud count equal to grid cells minus omitted
   (background) cells.
2. **Consistency** — `parts.json` brick totals exactly match the brick count in the
   `.ldr` and the per-step totals in `instructions.pdf`.
3. **Determinism** — The same image + config produces byte-identical grid and brick
   lists across runs (no randomness unless dithering is explicitly enabled).
4. **Latency** — P50 end-to-end job time ≤ 30 s and P95 ≤ 90 s for a 48×48 grid
   without background removal on the reference worker.
5. **Reliability** — ≥ 99% of valid uploads complete without an `error` status;
   invalid uploads fail fast with an actionable message.
6. **Usability** — The mobile client can upload, poll, and download all four
   artifacts end-to-end.

---

## 8. Testing & Validation

- **Unit** — Grid projection (aspect/cover-fit), quantization (known color →
  expected palette entry), packing (run-length tiling, no overlaps, full coverage),
  LDraw line formatting, parts aggregation.
- **Golden-file** — A fixed set of input images with checked-in expected grid,
  brick list, and parts.json; CI fails on any diff.
- **LDraw validation** — Headless render of `model.ldr` (LDView CLI) must succeed
  and the rendered thumbnail must match the cover thumbnail within a tolerance.
- **Cross-artifact invariants** — Automated check that brick counts agree across
  `.ldr`, `parts.json`, and instruction steps (Success Criteria #2).
- **Load** — Sustained concurrent jobs to confirm queue/worker scaling and artifact
  cleanup.

---

## 9. Out of Scope (restated)

Background removal is **optional** in the MVP and off by default. Height-maps, 3D,
cost optimization, marketplace integration, accounts, and WebSockets are deferred
(see FUTURE_3D_PIPELINE.md).

---

## 10. Summary

The MVP delivers a deterministic 2-D pipeline — upload → grid → quantize → pack →
LDraw → instructions → parts — behind a small async API, validated by golden-file
tests and cross-artifact invariants, with explicit latency and reliability targets.