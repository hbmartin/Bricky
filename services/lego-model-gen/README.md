# LEGO Model Generation System

Deterministic backend that converts a 2D photo into a single-layer LEGO mosaic:
LDraw `model.ldr`, `instructions.pdf`, `parts.json`, `thumbnail.png`, and `meta.json`.

Implements the contracts documented in `docs/LEGO Model Generation System/`.

## Pipeline

```
JobConfig -> ColorGrid -> [Brick] -> { LDraw, PartsList, Instructions, Meta }
```

- **vision** — normalize -> cover-fit crop -> linear-light area average -> CIELAB
  nearest-color quantization to the palette.
- **packing** — row-based run-length tiling into 1×1–1×4 plates (greedy longest-first).
- **ldraw** — ordered `.ldr` export (1 stud = 20 LDU).
- **parts** — aggregate by (part, color) with LDraw / BrickLink / Rebrickable IDs.
- **instructions** — row-by-row PDF + PNG thumbnail.

## Run locally

```bash
python3 -m venv .venv
.venv/bin/pip install -e ".[dev]"
.venv/bin/uvicorn app.api:app --reload
```

## API

| Method | Path                         | Purpose                          |
| ------ | ---------------------------- | -------------------------------- |
| POST   | `/jobs`                      | Create a job (multipart upload)  |
| GET    | `/jobs/{id}`                 | Poll status / progress           |
| GET    | `/jobs/{id}/result`          | Artifact URLs once done          |
| GET    | `/artifacts/{id}/{name}`     | Download a published artifact    |

## Test

```bash
.venv/bin/pytest -q
```

Determinism and cross-artifact brick-count consistency are enforced by the suite.
