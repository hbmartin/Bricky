# LEGO Model Generation System — Documentation

This repository contains the full technical documentation for a system that converts 2D images (and eventually 3D objects) into LEGO mosaics, LDraw models, instructions, and parts lists.  
All documents are located in the `docs/LEGO Model Generation System` directory and are designed to be modular, readable, and implementation‑ready.

---

## 1. Documentation Index

### Core Architecture

- [LEGO_MODEL_GENERATION_SYSTEM.md](LEGO_MODEL_GENERATION_SYSTEM.md)  
  High‑level system architecture, major subsystems, data flow, and future expansion.

### Shared Data Contracts

- [DATA_CONTRACTS.md](DATA_CONTRACTS.md)  
  Canonical schemas shared by every stage: job config, color grid, brick list,
  parts list, palette, and part/color mapping tables. **Read this before changing
  any per-stage JSON.**

### Vision & Image Processing

- [VISION_PIPELINE.md](VISION_PIPELINE.md)  
  Image preprocessing, grid projection, LEGO color quantization, and optional background removal.

### Brick Generation

- [BRICK_PACKING.md](BRICK_PACKING.md)  
  Algorithms for converting color grids into physical LEGO bricks, from simple row‑based packing to advanced stability‑aware and cost‑optimized approaches.

### LDraw Export

- [LDRAW_EXPORT.md](LDRAW_EXPORT.md)  
  Specification for generating .ldr/.mpd files, coordinate system, part mapping, and export rules.

### Instruction Generation

- [INSTRUCTIONS_GENERATOR.md](INSTRUCTIONS_GENERATOR.md)  
  Step planning, rendering, and PDF assembly for LEGO‑style building instructions.

### Parts & Inventory

- [PARTS_INVENTORY.md](PARTS_INVENTORY.md)  
  Brick counting, color/part mapping, and generation of parts.json for BrickLink/Rebrickable compatibility.

### API Design

- [API_DESIGN.md](API_DESIGN.md)  
  REST API for job creation, status polling, and artifact retrieval.

### MVP Plan

- [MVP_PLAN.md](MVP_PLAN.md)  
  Scope, architecture, pipeline, deliverables, and success criteria for the initial product release.

### Future 3D Pipeline

- [FUTURE_3D_PIPELINE.md](FUTURE_3D_PIPELINE.md)  
  Long‑term roadmap for 3D reconstruction, voxelization, 3D brick packing, and 3D instruction generation.

---

## 2. System Summary

The system converts an input image into a complete LEGO build package:

1. Preprocess image  
2. Convert to LEGO color grid  
3. Pack bricks  
4. Export LDraw model  
5. Generate instructions  
6. Produce parts list  
7. Deliver artifacts via API  

The architecture is modular and designed for future expansion into 3D scanning and advanced optimization.

---

## 3. Repository Structure

All documents live in `docs/LEGO Model Generation System/`:

    README.md
    LEGO_MODEL_GENERATION_SYSTEM.md   (architecture overview)
    DATA_CONTRACTS.md                 (shared schemas — source of truth)
    VISION_PIPELINE.md
    BRICK_PACKING.md
    LDRAW_EXPORT.md
    INSTRUCTIONS_GENERATOR.md
    PARTS_INVENTORY.md
    API_DESIGN.md
    MVP_PLAN.md
    FUTURE_3D_PIPELINE.md

---

## 4. Getting Started

To implement the MVP:

1. Lock the shared schemas in [DATA_CONTRACTS.md](DATA_CONTRACTS.md).
2. Build the API endpoints from [API_DESIGN.md](API_DESIGN.md).  
3. Implement the worker pipeline following [MVP_PLAN.md](MVP_PLAN.md).  
4. Use the 2D vision pipeline ([VISION_PIPELINE.md](VISION_PIPELINE.md)).  
5. Apply simple row‑based brick packing ([BRICK_PACKING.md](BRICK_PACKING.md)).  
6. Export LDraw ([LDRAW_EXPORT.md](LDRAW_EXPORT.md)).  
7. Generate instructions ([INSTRUCTIONS_GENERATOR.md](INSTRUCTIONS_GENERATOR.md)).  
8. Produce parts list ([PARTS_INVENTORY.md](PARTS_INVENTORY.md)).  

This produces a complete, downloadable LEGO mosaic package.

---

## 5. Future Work

After MVP launch, expand into:

- Background removal  
- Height‑map reliefs  
- Advanced brick packing  
- Marketplace integration  
- User accounts  
- WebSockets  
- Full 3D reconstruction (see [FUTURE_3D_PIPELINE.md](FUTURE_3D_PIPELINE.md))  

---

## 6. License

To be defined by the project owner.

---

## 7. Maintainers

Ami and contributors.

---

This README links the entire documentation set and provides a clear entry point for developers, contributors, and future maintainers.
