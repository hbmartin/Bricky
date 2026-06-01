# Brick Packing Algorithms

This document describes algorithms for converting a LEGO‑color grid into a set of physical LEGO bricks.

---

## 1. v1 Algorithm — Row‑Based Packing

### Steps
1. For each row:
   - Identify runs of same color.
   - Fill runs with longest allowed bricks.
2. Allowed bricks (pinned by the shared part table — see §4):
   - 1×4  
   - 1×3  
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
]```

The brick list is the authoritative Brick List Contract (see DATA_CONTRACTS.md
§4); LDraw export, instructions, and the parts list all consume it unchanged.

---

## 5. Invariants (enforced in tests)

Every packer version — v1 through v3 — must satisfy the same correctness
invariants. Only the *quality* of the packing (seam alignment, cost) improves
across versions; the contract never weakens.

1. **Full coverage** — Σ `length` over all bricks equals the number of
   non-`null` grid cells. Every colored stud is covered exactly once.
2. **No overlap** — No two bricks occupy the same stud.
3. **Color fidelity** — Each brick's `color` matches the grid cells it covers; a
   single brick never spans two different colors.
4. **Part/length consistency** — `part` is pinned by `length` via the shared part
   table (1→`3024`, 2→`3023`, 3→`3623`, 4→`3710`). No inline magic numbers.
5. **Determinism** — The same color grid produces a byte-identical brick list
   across runs (no randomness in the MVP packer).

---

## 6. MVP Scope

The MVP ships **v1 (row-based packing)** only. v2 (stability-aware) and v3
(cost-optimized) are documented here as the forward roadmap but are out of scope
for the first release (see MVP_PLAN.md §2). The v1 allowed-part set is 1×1, 1×2,
1×3, and 1×4 plates laid flat (studs up).

---

## 7. Summary

Brick packing converts the quantized color grid into an ordered, fully-covering,
non-overlapping brick list. The MVP uses simple per-row run-length tiling (v1);
later versions add seam-aware stability (v2) and cost optimization (v3) without
changing the output contract or its invariants.