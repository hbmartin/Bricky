# Brick Packing Algorithms

This document describes algorithms for converting a LEGO‑color grid into a set of physical LEGO bricks.

---

## 1. v1 Algorithm — Row‑Based Packing

### Steps
1. For each row:
   - Identify runs of same color.
   - Fill runs with longest allowed bricks.
2. Allowed bricks:
   - 1×4  
   - 1×2  
   - 1×1

### Pros
- Simple.
- Fast.
- Good for mosaics.

### Cons
- Seams may align.
- Not cost‑optimized.

---

## 2. v2 Algorithm — Stability‑Aware Packing

### Enhancements
- Penalize seams that align with the row below.
- Prefer bricks that cross seams.
- Use dynamic programming per row.

### Implementation Notes
- When packing row *y*, inspect seams in row *y − 1*.
- Apply a penalty weight for aligned seams.
- Choose brick placements minimizing total penalty.

---

## 3. v3 Algorithm — Cost‑Optimized Packing

### Enhancements
- Assign cost per part type (e.g., 1×4 cheaper than four 1×1).
- Minimize total cost while maintaining stability.
- Use dynamic programming or integer linear programming (ILP).

### Example Objective
Minimize  


\[
\text{Total Cost} = \sum_i c_i \cdot n_i
\]


subject to coverage and stability constraints.

---

## 4. Output Format

Part IDs **must** come from the shared part table (see LDRAW_EXPORT.md §4 /
DATA_CONTRACTS.md): 1×1 → `3024`, 1×2 → `3023`, 1×3 → `3623`, 1×4 → `3710`.

```json
[
  { "x": 0, "y": 0, "length": 4, "color": "Bright Red", "part": "3710" },
  { "x": 4, "y": 0, "length": 2, "color": "Bright Red", "part": "3023" },
  { "x": 6, "y": 0, "length": 1, "color": "Bright Red", "part": "3024" }
]
