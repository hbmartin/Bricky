# Data Contracts — Shared Schemas

This document is the **single source of truth** for the data that flows between
stages of the LEGO Model Generation System. Every other document (vision, packing,
LDraw export, instructions, parts, API) must conform to the schemas here. When a
schema changes, update this file first, then the consuming docs.

The pipeline is a linear contract:

    Job Config → Color Grid → Brick List → { LDraw model, Parts List, Instructions }

---

## 1. Conventions

- All coordinates are **integers**. Grid coordinates are in **studs**; LDraw
  coordinates are in **LDU** (1 stud = 20 LDU).
- Grid origin `(x=0, y=0)` is the **top-left** stud (row 0 = image top).
- Color **names** are the interchange key between stages; numeric color IDs
  (LDraw/BrickLink/Rebrickable) are resolved only via the Color Contract (§6).
- Part **IDs** are LDraw/BrickLink design numbers as strings (e.g., `"3710"`).
- JSON is UTF-8. Times are ISO-8601 UTC.

---

## 2. Job Config Contract

Produced by the API from the upload request; consumed by the worker.

```json
{
  "job_id": "abc123",
  "created_at": "2026-05-31T18:00:00Z",
  "image_ref": "s3://uploads/abc123/source.png",
  "grid": { "width": 48, "height": 48 },
  "palette_id": "mvp-v1",
  "background_removal": false,
  "dither": false
}
```

- `grid.width` / `grid.height` are the **snapped** preset values
  (see VISION_PIPELINE.md §4.1), not the raw request values.
- `palette_id` references a registered palette (§5).

---

## 3. Color Grid Contract

Output of the vision pipeline; sole input to brick packing.

```json
{
  "width": 48,
  "height": 48,
  "palette_id": "mvp-v1",
  "cells": [
    ["Black", "Black", "Bright Red", "..."],
    ["Black", "Bright Red", null, "..."]
  ]
}
```

- `cells` is **row-major**: `cells.length == height`, `cells[r].length == width`.
- Each entry is a palette color **name** or `null` (omitted/background stud).

---

## 4. Brick List Contract

Output of brick packing; input to LDraw export, instructions, and parts.

```json
[
  { "x": 0, "y": 0, "length": 4, "color": "Bright Red", "part": "3710" },
  { "x": 4, "y": 0, "length": 2, "color": "Bright Red", "part": "3023" },
  { "x": 6, "y": 0, "length": 1, "color": "Bright Red", "part": "3024" }
]
```

- `x`, `y` — stud coordinates of the brick's left-most stud (top-left for 2-D).
- `length` — run length in studs along +X.
- `color` — palette color name (must exist in the active palette).
- `part` — LDraw part ID; **must** match `length` via the Part Contract (§7).

Invariants (enforced in tests):

1. No two bricks overlap.
2. Σ `length` over all bricks == number of non-`null` grid cells.
3. `part` is consistent with `length` (1→`3024`, 2→`3023`, 3→`3623`, 4→`3710`).

---

## 5. Parts List Contract (`parts.json`)

Output of the Parts & Inventory service.

```json
{
  "palette_id": "mvp-v1",
  "parts": [
    {
      "part": "3710",
      "color": "Bright Red",
      "qty": 12,
      "ldraw_color": 4,
      "bricklink_color": 5,
      "rebrickable_color": 4
    }
  ],
  "total_parts": 1234
}
```

- `total_parts` == Σ `qty` == number of bricks in the Brick List.

---

## 6. Color Contract (palette + color IDs)

A palette is a registered list of colors. Each entry is the interchange name plus
its cross-system IDs. **These tables are generated from Rebrickable's `colors.csv`
(which carries external BrickLink and LDraw IDs), never hand-entered.**

```json
{
  "palette_id": "mvp-v1",
  "colors": [
    { "name": "Black",            "ldraw": 0,  "bricklink": 11, "rebrickable": 0  },
    { "name": "White",            "ldraw": 15, "bricklink": 1,  "rebrickable": 15 },
    { "name": "Bright Red",       "ldraw": 4,  "bricklink": 5,  "rebrickable": 4  },
    { "name": "Bright Blue",      "ldraw": 1,  "bricklink": 7,  "rebrickable": 1  },
    { "name": "Dark Bluish Gray", "ldraw": 72, "bricklink": 85, "rebrickable": 72 }
  ]
}
```

> Numeric IDs differ wildly across systems and are easy to get wrong (BrickLink 21
> is Light Purple; Rebrickable 1 is Blue). Treat any hand-written ID as suspect
> until validated against `colors.csv`.

---

## 7. Part Contract (geometry ↔ LDraw part)

The canonical mapping from brick geometry to LDraw part file. Plates are used for
mosaics (flat, studs-up wall); bricks/tiles are introduced later. See "Terminology"
in LEGO_MODEL_GENERATION_SYSTEM.md.

| Geometry | LDraw part | File        | BrickLink | Rebrickable |
| -------- | ---------- | ----------- | --------- | ----------- |
| Plate 1×1 | 3024      | `3024.dat`  | 3024      | 3024        |
| Plate 1×2 | 3023      | `3023.dat`  | 3023      | 3023        |
| Plate 1×3 | 3623      | `3623.dat`  | 3623      | 3623        |
| Plate 1×4 | 3710      | `3710.dat`  | 3710      | 3710        |
| Plate 2×2 | 3022      | `3022.dat`  | 3022      | 3022        |
| Plate 2×4 | 3020      | `3020.dat`  | 3020      | 3020        |

The MVP packer emits only 1×1, 1×2, 1×3, 1×4 plates (see BRICK_PACKING.md).

---

## 8. Job Metadata Contract (`meta.json`)

Written alongside artifacts; consumed by the client to render a summary.

```json
{
  "job_id": "abc123",
  "grid": { "width": 48, "height": 48 },
  "palette_id": "mvp-v1",
  "brick_count": 1234,
  "stud_count": 2304,
  "warnings": ["low_detail"],
  "engine_version": "1.0.0"
}
```

- `warnings` is a list of machine-readable flags (e.g., `low_detail`,
  `background_removal_failed`).

---

## 9. Versioning

- `engine_version` (semver) stamps every job and `meta.json`.
- `palette_id` is versioned (`mvp-v1`, `mvp-v2`, …); palettes are immutable once
  published so old jobs remain reproducible.
- Breaking a schema requires a major `engine_version` bump and an update here.
