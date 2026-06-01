
# Instruction Generator Design

This document defines how to generate step‑by‑step LEGO building instructions for mosaic and low‑relief models. The instruction generator consumes the packed brick list and produces a structured PDF containing a cover page, parts list, and build steps.

---

## 1. Overview

The instruction generator transforms a list of placed bricks into a human‑readable, step‑by‑step instruction manual.  
For 2D mosaics, instructions are top‑down and emphasize clarity, color accuracy, and incremental assembly.

The pipeline consists of:

1. Step planning  
2. Rendering  
3. PDF assembly  

---

## 2. Step Planning

Step planning determines which bricks appear in each instruction step.

### 2.1 Strategy A — Row‑by‑Row (MVP)

- Step 1: place all bricks in row 0  
- Step 2: place all bricks in row 1  
- …  
- Simple and predictable  
- Works well for mosaics

### 2.2 Strategy B — Band‑by‑Band

- Group 2–4 rows per step  
- Reduces total number of pages  
- Good for large mosaics

### 2.3 Strategy C — Brick‑Count‑Based

- Add bricks until a threshold (e.g., 20–40 bricks)  
- Start a new step  
- Produces consistent step complexity

### 2.4 Sorting

Bricks should be sorted by:

1. Layer  
2. Y coordinate (top to bottom or bottom to top)  
3. X coordinate  

This ensures deterministic output.

---

## 3. Rendering

Rendering produces an image for each step.

### 3.1 View Mode

For mosaics:

- Orthographic top‑down view  
- No perspective  
- No rotation  

### 3.2 Grid

- Draw a faint grid of studs  
- Each stud corresponds to one cell in the mosaic  
- Grid helps users align bricks

### 3.3 Brick Visualization

#### Existing Bricks (from previous steps)
- Draw in normal color  
- No highlight  
- Slightly lower opacity optional

#### New Bricks (for this step)
- Draw in full color  
- Add a bold outline or glow  
- Optional: number the bricks

### 3.4 Rendering Tools

Recommended:

- **Pillow** (Python)  
- **Cairo**  
- **Node + Canvas**  
- **Three.js (optional)** for 3D‑style rendering

### 3.5 Rendering Algorithm

1. Build a 2D array representing the mosaic state up to the current step.  
2. Draw the grid.  
3. Draw all existing bricks.  
4. Draw new bricks with highlight.  
5. Export as PNG.

---

## 4. PDF Assembly

The final PDF contains:

### 4.1 Cover Page

- Title  
- Thumbnail of final mosaic  
- Dimensions (studs)  
- Total brick count  

### 4.2 Parts List Page

- Table of:
  - Part ID  
  - Color  
  - Quantity  
- Optional: BrickLink/Rebrickable IDs

### 4.3 Step Pages

Each page includes:

- Step number  
- Rendered step image  
- Optional: list of bricks added in this step  

### 4.4 Tools

- **ReportLab**  
- **fpdf**  
- **img2pdf**  

---

## 5. Output Format

The instruction generator outputs:

instructions.pdf

Alongside:

- `model.ldr`  
- `parts.json`  

---

## 6. Performance Considerations

- Rendering is O(W × H × steps).  
- Use caching for repeated background layers.  
- Pre‑render the final mosaic for the cover page.

---

## 7. Future Enhancements

### 7.1 3D Instruction Support

- Perspective view  
- Rotated camera angles  
- Submodel breakdowns  

### 7.2 Advanced Highlighting

- Animated transitions  
- Step overlays  
- Brick numbering  

### 7.3 LPub4 / WebLic Integration

- Export `.ldr` with meta commands  
- Allow external instruction engines to render steps  

### 7.4 Multi‑Layer Support

- Show plate height differences  
- Render shadows for depth cues  

---

## 8. Summary

The instruction generator converts packed bricks into a polished PDF instruction manual using:

- Step planning  
- Top‑down rendering  
- PDF assembly  

This system produces clear, LEGO‑style instructions suitable for mosaics and low‑relief builds.
