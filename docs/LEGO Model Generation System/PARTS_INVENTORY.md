# Parts & Inventory Service

This document defines how to compute, aggregate, and map LEGO parts for the generated mosaic or model. The service consumes the packed brick list and outputs a structured parts inventory compatible with BrickLink, Rebrickable, and LDraw.

---

## 1. Overview

The Parts & Inventory Service performs three core tasks:

1. Count all bricks by part and color.
2. Map internal part/color identifiers to external systems.
3. Produce a machine‑readable parts.json file for downstream use.

This service is stateless and runs after brick packing and LDraw export.

---

## 2. Part Counting

Given a list of placed bricks, the service aggregates them by:

- Part ID
- Color
- Length (for plates/bricks with variants)

### 2.1 Input Format (example)

Part IDs follow the shared part table (1×4 → `3710`, 1×2 → `3023`, 1×1 → `3024`;
see LDRAW_EXPORT.md §4 / DATA_CONTRACTS.md):

[
  { "x": 0, "y": 0, "length": 4, "color": "Bright Red", "part": "3710" },
  { "x": 4, "y": 0, "length": 2, "color": "Bright Red", "part": "3023" },
  { "x": 6, "y": 0, "length": 1, "color": "Bright Red", "part": "3024" }
]

### 2.2 Aggregation Logic

Group by (part, color):

(Bright Red, 3710) → 1  
(Bright Red, 3023) → 1  
(Bright Red, 3024) → 1

### 2.3 Output Example

parts:  
- part: 3710, color: Bright Red, qty: 12  
- part: 3024, color: Bright Red, qty: 48  
- part: 3023, color: Bright Blue, qty: 6

---

## 3. Color Mapping

Internal color names must map to:

- LDraw color IDs
- BrickLink color IDs
- Rebrickable color IDs

### 3.1 Example Mapping

Bright Red → ldraw: 4, bricklink: 5, rebrickable: 4  
Dark Bluish Gray → ldraw: 72, bricklink: 85, rebrickable: 72

> These IDs are **not** interchangeable across systems (e.g., BrickLink 21 is Light
> Purple and Rebrickable 1 is Blue — neither is red). The canonical mapping table
> must be generated from Rebrickable's `colors.csv` (which carries external
> BrickLink/LDraw IDs) rather than hand-entered, and is the single source of truth
> referenced by DATA_CONTRACTS.md → Color Contract.

### 3.2 Palette Considerations

- Avoid rare/discontinued colors.
- Use a stable, well‑supported palette.
- Allow user‑selectable palettes in future versions.

---

## 4. Part Mapping

Each internal part ID must map to:

- LDraw part file
- BrickLink part number
- Rebrickable part number

### 4.1 Example Mapping

3024 → Plate 1×1, ldraw: 3024.dat, bricklink: 3024, rebrickable: 3024  
3023 → Plate 1×2, ldraw: 3023.dat, bricklink: 3023, rebrickable: 3023

---

## 5. Output Format

The final output is a JSON‑style structure:

parts:  
- part: 3023  
  color: Bright Red  
  qty: 42  
  ldraw_color: 4  
  bricklink_color: 5  
  rebrickable_color: 4  

total_parts: 1234

> The IDs above are the **correct** cross-system values for Bright Red
> (LDraw 4, BrickLink 5, Rebrickable 4), resolved from `colors.csv` per
> DATA_CONTRACTS.md §6. Do **not** hand-enter BrickLink 21 (Light Purple) or
> Rebrickable 1 (Blue) — see the warning in §3.1.

---

## 6. Integration Points

### 6.1 LDraw Export

- Uses LDraw color IDs.
- Uses LDraw part filenames.

### 6.2 Instruction Generator

- Uses part list for the parts page.
- Optionally shows per‑step brick usage.

### 6.3 External Marketplaces (Future)

- BrickLink API for purchasing.
- Rebrickable API for inventory matching.

---

## 7. Performance Considerations

- Counting is O(n) where n = number of bricks.
- Mapping is O(n) with dictionary lookups.
- JSON output is small (typically under 50 KB).

---

## 8. Future Enhancements

### 8.1 User Inventory Matching

- Allow users to upload their existing brick inventory.
- Optimize builds to minimize new purchases.

### 8.2 Cost Estimation

- Estimate cost using BrickLink average prices.
- Provide low‑cost alternative parts.

### 8.3 Color Substitution

- Suggest alternative colors when exact matches are unavailable.
- Allow palette reduction for cost savings.

---

## 9. Summary

The Parts & Inventory Service aggregates bricks, maps them to external systems, and produces a structured parts list. This enables instruction generation, marketplace integration, and future inventory‑aware optimizations.
