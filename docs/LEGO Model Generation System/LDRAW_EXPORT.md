# LDraw Export Specification

This document defines how to convert packed LEGO bricks into a valid LDraw model. The output is used for instruction generation, rendering, and interoperability with LEGO CAD tools.

---

## 1. Overview

The LDraw export stage transforms a list of placed bricks into a .ldr or .mpd file. Each brick is represented as a single line containing:

- Color ID
- Position (x, y, z)
- Orientation matrix
- Part filename

---

## 2. Coordinate System

LDraw uses a right‑handed coordinate system in which **−Y is up**
(Y **increases downward**). This is the single most common source of
upside‑down exports — do not assume Y points up.

- X axis: left → right (X increases to the right)
- Y axis: top → bottom (**−Y is up; Y increases downward**)
- Z axis: depth; with the mosaic facing the builder, studs point toward the
  viewer and successive layers recede away from the viewer

### Stud Scaling

One LEGO stud = 20 LDraw units (LDU). Plate height = 8 LDU; brick height = 24 LDU
(3 plates).

For a mosaic built as a vertical wall facing the builder (studs toward the viewer):

- `X = column index × 20`
- `Y = row index × 20` — because −Y is up, **row 0 (image top) maps to the
  smallest Y** and rows increase downward, which matches image row order. No
  vertical flip is needed; the formula is correct precisely because Y grows down.
- `Z = −(layer index) × 8` for plate layers or `× 24` for brick layers — a
  single‑layer mosaic uses `Z = 0`; additional relief layers recede along −Z.

> Sanity check: after export, the top of the source image must appear at the top
> of the rendered model in LDView/LeoCAD. If it is flipped, the Y sign is wrong.

---

## 3. Brick Placement Format

Each brick is written as:

1 <color_id> <x> <y> <z>  1 0 0  0 1 0  0 0 1  <part_id>.dat

### Field Definitions

- 1 — line type (part reference)
- <color_id> — LDraw color ID
- <x> <y> <z> — position in LDraw units
- 1 0 0 0 1 0 0 0 1 — identity matrix (no rotation)
- <part_id>.dat — LDraw part filename

---

## 4. Part Mapping

### Common Plate Parts

- 1×1 → 3024.dat
- 1×2 → 3023.dat
- 1×3 → 3623.dat
- 1×4 → 3710.dat
- 2×2 → 3022.dat
- 2×4 → 3020.dat

### Color Mapping Example

Bright Red → 4  
Bright Blue → 1  
Black → 0  
White → 15  
Dark Bluish Gray → 72

---

## 5. File Structure

### 5.1 Single‑File Mosaic (.ldr)

For the MVP, the entire mosaic is a single `.ldr` file: a header block followed by
one part‑reference line per brick, sorted deterministically.

```ldr
0 Mosaic Model
0 Name: model.ldr
0 Author: Bricky Model Generation System
0 !LDRAW_ORG Unofficial_Model
0 BFC CERTIFY CCW
1 4 0 0 0 1 0 0 0 1 0 0 0 1 3024.dat
1 4 20 0 0 1 0 0 0 1 0 0 0 1 3024.dat
1 4 40 0 0 4 0 0 0 1 0 0 0 1 3710.dat
```

### 5.2 Line Ordering (deterministic)

Bricks **must** be written in a stable order so exports are reproducible and match
the instruction step order:

1. Layer (Z), back‑to‑front
2. Row (Y), top‑to‑bottom
3. Column (X), left‑to‑right

### 5.3 Orientation Matrix

The MVP uses the identity matrix (`1 0 0 0 1 0 0 0 1`) for all bricks. A 1×N plate
is oriented along X by default; if a part's native LDraw orientation runs along Z,
apply a 90° Y rotation (`0 0 1 0 1 0 -1 0 0`). Part‑specific orientation lives in
the part‑mapping table, not in ad‑hoc code.

### 5.4 Header Meta Lines

- `0 <title>` — human title (first line).
- `0 Name:` / `0 Author:` — provenance.
- `0 !LDRAW_ORG Unofficial_Model` — marks a generated, non‑official model.
- `0 BFC CERTIFY CCW` — back‑face culling certification for correct rendering.

### 5.5 Multi‑File Model (.mpd) — Future

Large mosaics and all 3‑D models use `.mpd`, with one `0 FILE <name>` submodel per
baseplate tile or layer and a top‑level model that references them via `1` lines.
The MVP emits a single `.ldr`; `.mpd` is introduced with multi‑baseplate and 3‑D
export (see FUTURE_3D_PIPELINE.md §7).

---

## 6. Export Rules & Invariants

- Every brick maps to exactly one LDraw part file and one LDraw color ID, both
  taken from the shared palette/part tables (DATA_CONTRACTS.md). No inline magic
  numbers.
- No two bricks may overlap; total covered studs must equal non‑background grid
  cells. Validated against `parts.json` (see MVP_PLAN.md §8).
- Coordinates are integers in LDU; positions are multiples of 20 (X/Y) and of the
  layer height (Z).
- The file must load without warnings in LDView/LeoCAD before it is published.

---

## 7. Summary

LDraw export converts the ordered brick list into a single deterministic `.ldr`
(MVP) — correct −Y‑up coordinates, identity orientation, shared part/color tables,
and a BFC‑certified header — laying the groundwork for `.mpd` submodels in the 3‑D
pipeline.
