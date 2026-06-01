# Vision Pipeline — Image → LEGO Grid

This document defines the 2D vision pipeline that converts an input image into a stud‑aligned LEGO color grid suitable for brick packing and LDraw export.

---

## 1. Overview

The vision pipeline transforms a raw input image into a structured grid of LEGO‑compatible colors. This grid becomes the foundation for brick packing, instruction generation, and parts list creation.

The pipeline consists of:

1. Preprocessing  
2. Background removal (optional)  
3. Grid projection  
4. Color quantization  
5. Output formatting  

---

## 2. Preprocessing

### 2.1 Image Normalization
- Convert to RGB.
- Strip EXIF orientation and normalize orientation.
- Resize so the longest dimension ≤ **1024 px**.
- Maintain aspect ratio.

### 2.2 Optional Enhancements
- Contrast normalization.
- Light smoothing to reduce noise.
- Cropping (manual or automatic).

---

## 3. Background Removal (Optional for MVP)

Background removal improves mosaic quality for portraits and objects.

### 3.1 Recommended Models
- **U²‑Net** (fast, accurate)
- **Segment Anything (SAM)** (robust, heavier)
- **MODNet** (lightweight)

### 3.2 Output
- Transparent PNG with isolated foreground.
- Background pixels set to a neutral color or omitted.

---

## 4. Grid Projection

The image is mapped to a LEGO grid of size **W × H studs**.

### 4.1 Supported Grid Sizes (MVP)

The MVP exposes a fixed set of square and rectangular sizes aligned to standard
baseplate dimensions so that finished mosaics mount cleanly:

| Preset      | Studs (W × H) | Notes                                  |
| ----------- | ------------- | -------------------------------------- |
| Small       | 32 × 32       | One 32×32 baseplate. Fastest build.    |
| Medium      | 48 × 48       | Default. Good detail/effort balance.   |
| Large       | 64 × 64       | Four 32×32 baseplates (2 × 2 tiling).  |
| Portrait    | 48 × 64       | Vertical framing for faces/figures.    |
| Landscape   | 64 × 48       | Horizontal framing for scenes.         |

Constraints:

- Minimum dimension: **16 studs**. Below this, quantization detail is too coarse.
- Maximum dimension: **96 studs** (hard cap to bound worker cost and part count).
- `width` and `height` from the job request are **snapped** to the nearest
  supported preset; the chosen preset is echoed back in the job result metadata.

### 4.2 Aspect-Ratio Handling

1. Compute the target grid aspect ratio (W / H).
2. **Cover-fit** the source image to the grid: scale so the image fully covers the
   grid, then center-crop the overflow. This avoids letterbox padding that would
   produce dead background studs.
3. If `background_removal` is enabled, fit to the foreground bounding box first,
   then cover-fit that crop to the grid.

### 4.3 Cell Sampling

For each grid cell (x, y):

1. Map the cell to its source-image pixel region.
2. Compute the **area-weighted average color** of that region in linear RGB
   (de-gamma → average → re-gamma). Averaging in sRGB directly biases toward dark
   colors and must be avoided.
3. Store the averaged sRGB color as the cell's pre-quantization color.

Optional refinement (post-MVP): use the **median** or a small k-means (k = 1–2)
per cell to reduce the impact of edge pixels straddling two regions.

---

## 5. Color Quantization

Each averaged cell color is mapped to the nearest color in the active LEGO palette.

### 5.1 Palette

The MVP ships a single curated, in-production palette (rare/retired colors are
excluded). Each palette entry carries the canonical name plus its LDraw, BrickLink,
and Rebrickable color IDs (see DATA_CONTRACTS.md → Color Contract). The palette is
the single source of truth shared by quantization, LDraw export, and the parts list.

Baseline MVP palette (extensible): Black, White, Light Bluish Gray,
Dark Bluish Gray, Bright Red, Bright Blue, Bright Yellow, Bright Green,
Dark Orange, Reddish Brown, Bright Orange, Medium Azure, Bright Pink, Tan.

### 5.2 Nearest-Color Search

1. Convert the cell color and every palette color from sRGB to **CIELAB**.
2. Compute perceptual distance using **CIEDE2000** (preferred) or CIE76 ΔE as a
   faster fallback.
3. Assign the palette color with the smallest distance.

### 5.3 Optional Dithering

For photographic inputs, **Floyd–Steinberg** error diffusion across the grid
reduces banding. Dithering is **off by default** for the MVP (it complicates the
brick-packing seams and parts count) and is exposed as an opt-in flag.

### 5.4 Single-Color and Low-Contrast Guards

- If ≥ 95% of cells quantize to one color, flag `low_detail` in job metadata so the
  client can warn the user before they build a near-blank mosaic.
- Background-removed images set cropped-out cells to a designated background color
  (default: none → those cells are omitted from packing, producing a silhouette).

---

## 6. Output Format

The pipeline emits a **color grid** that is the sole input to brick packing:

```json
{
  "width": 48,
  "height": 48,
  "palette_id": "mvp-v1",
  "cells": [
    [ "Black", "Black", "Bright Red", "..." ],
    [ "Black", "Bright Red", "Bright Red", "..." ]
  ]
}
```

- `cells` is a row-major 2-D array of palette color **names** (not raw RGB), with
  `cells.length == height` and each row length `== width`.
- A `null` cell denotes an omitted (transparent/background) stud.
- See DATA_CONTRACTS.md → Grid Contract for the authoritative schema.

---

## 7. Performance Considerations

- Preprocessing and grid projection are O(pixels); quantization is
  O(cells × palette size) and trivially parallelizable per cell.
- Cache the LAB conversion of the palette once per job (palette is small).
- Background removal (U²-Net/MODNet) dominates latency; run it on GPU when
  available and skip entirely when `background_removal` is false.

---

## 8. Summary

The vision pipeline normalizes the input, optionally isolates the foreground,
projects the image onto a stud-aligned grid, and quantizes each cell to the shared
LEGO palette using perceptual (CIELAB/CIEDE2000) distance. Its output is a
deterministic color grid consumed by brick packing, LDraw export, instruction
generation, and the parts list.

