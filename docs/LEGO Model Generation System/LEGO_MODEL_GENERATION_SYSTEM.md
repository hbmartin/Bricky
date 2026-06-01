# LEGO Model Generation System — Architecture Overview

This document provides a complete, high‑level architecture for the system that converts 2D images (and eventually 3D objects) into LEGO models, LDraw files, instructions, and parts lists.

---

## 1. System Goals

- Convert any 2D image into a LEGO mosaic or low‑relief model.
- Generate a valid LDraw model.
- Produce step‑by‑step instructions.
- Output a parts list with BrickLink/Rebrickable mappings.
- Provide a clean mobile app interface for capture and download.
- Support future expansion into full 3D object scanning.

---

## 2. Major Subsystems

### 2.1 Mobile Client
- Capture image.
- Configure mosaic size and color options.
- Upload to backend.
- Poll job status.
- Display results and allow downloads.

### 2.2 API Gateway
- `/jobs` endpoint for job creation.
- Authentication and rate limiting.
- Result retrieval.
- Input validation.

### 2.3 Job Orchestrator
- Queue system (Redis/RabbitMQ/SQS).
- Worker pool for processing.
- Progress tracking and status updates.
- Error handling and retries.

### 2.4 Vision & Geometry Service
- Background removal.
- Image → grid mapping.
- Color quantization to LEGO palette.
- Optional height‑map generation for low‑relief builds.
- Future: multi‑view 3D reconstruction.

### 2.5 LEGO Model Synthesis
- Brick packing algorithms.
- Stability heuristics.
- Cost‑aware optimization (future).
- LDraw export.

### 2.6 Instruction Generator
- Step planning.
- Rendering of each step.
- PDF assembly.
- Optional integration with LPub4/WebLic.

### 2.7 Parts & Inventory Service
- Part counting.
- Color and part ID mapping.
- BrickLink/Rebrickable compatibility.
- Cost estimation.

---

## 3. Data Flow

1. Mobile app uploads image → `/jobs`.
2. Backend creates job and enqueues it.
3. Worker processes job:
   - Vision pipeline.
   - Brick packing.
   - LDraw export.
   - Instruction generation.
   - Parts list creation.
4. Worker stores results in object storage.
5. Client polls `/jobs/{id}`.
6. Client downloads PDF, LDraw, and parts list.

---

## 4. Technology Stack (Recommended)

### Backend
- Python (FastAPI) or Node.js.
- Redis/RabbitMQ/SQS for job queue.
- S3-compatible storage for artifacts.

### Vision
- Python + Pillow/OpenCV.
- Optional: PyTorch for segmentation.

### Rendering
- Pillow/Cairo for 2D.
- Optional: Three.js/Node for 3D.

### Mobile
- React Native or Flutter.

---

## 5. Future Extensions

### 5.1 Full 3D Reconstruction
- Multi‑view capture.
- NeRF or COLMAP.
- Mesh → voxel → LEGO conversion.

### 5.2 Marketplace Integration
- BrickLink API for purchasing parts.
- Rebrickable API for part mapping.

### 5.3 User Inventory Awareness
- Track user’s existing bricks.
- Optimize builds based on available inventory.

### 5.4 Advanced Brick Packing
- ILP solvers for cost optimization.
- Structural analysis for stability.

---

## 6. Terminology

To avoid the plate/brick confusion that appears throughout LEGO tooling:

- **Stud** — a single grid cell / connection point. 1 stud = 20 LDU = 8 mm pitch.
- **Plate** — a 1-plate-tall element (8 LDU / 3.2 mm). Mosaics are built from
  **plates** laid flat (studs up), so the MVP packer/exporter use plate parts
  (`3024`, `3023`, `3623`, `3710`).
- **Brick** — a 3-plate-tall element (24 LDU / 9.6 mm), used for relief/3-D builds.
- Throughout the docs, "brick list" is the generic term for placed elements even
  when those elements are plates; the actual part is pinned by the Part Contract
  (DATA_CONTRACTS.md §7).

> Note: the in-app SceneKit renderer (`BrickGeometryGenerator`) works in
> **millimeters** (8 mm pitch, 3.2 mm plate, 9.6 mm brick); this backend works in
> **LDU** (20 / 8 / 24). 1 stud = 20 LDU = 8 mm. Keep the two unit systems
> explicit at every boundary.

---

## 7. Security, Privacy & Content Safety

User uploads are photos, frequently of **people** (portraits/faces), so this is
PII and must be handled accordingly:

- **In transit / at rest** — TLS for all transfers; encrypt stored uploads and
  artifacts (S3 SSE or equivalent).
- **Retention** — Source uploads are deleted promptly after processing (default:
  within 24 h, or immediately on job completion). Generated artifacts have a TTL
  (see §8). No source image is retained for training without explicit opt-in.
- **Access** — Artifact URLs are unguessable and time-limited (signed URLs); a job
  ID alone must not grant access to another user's results.
- **Content moderation** — Background-removal/segmentation runs on arbitrary user
  content; add a moderation/abuse policy before any public/community exposure.
- **Compliance** — Provide deletion-on-request and a documented retention policy
  (GDPR/CCPA). Do not log raw image bytes.

---

## 8. Artifact Storage & Lifecycle

- Artifacts (`model.ldr`, `instructions.pdf`, `parts.json`, `thumbnail.png`,
  `meta.json`) are written to S3-compatible storage and served via CDN.
- Each job's artifacts carry a **TTL** (default 30 days) after which they are
  garbage-collected; the client is told the expiry in the result payload.
- Storage keys are namespaced by `job_id`; cleanup is idempotent and safe to retry.
- Failed jobs leave no partial artifacts (write-then-publish, never publish-partial).

---

## 9. Observability & Operations

- **Status & progress** — Workers emit `progress` (0–100) per stage so the API can
  report meaningful polling responses.
- **Metrics** — Per-stage latency, job success/error rate, queue depth, artifact
  size, and worker saturation.
- **Logging** — Structured logs keyed by `job_id` and `engine_version`; never log
  image bytes or signed URLs.
- **Failure handling** — Bounded retries with idempotent stages; a job that
  exhausts retries ends in `error` with an actionable message (see API_DESIGN.md).

---

## 10. Summary

This architecture supports:
- A robust 2D MVP.
- Clean separation of concerns.
- Scalable backend processing.
- Future expansion into 3D and advanced features.

It is designed for modularity, maintainability, and long‑term growth of the LEGO generation platform.
