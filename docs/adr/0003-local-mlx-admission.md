# ADR 0003: Local MLX recovery requires runtime admission

- Status: Accepted with physical-device release gate
- Date: 2026-08-02

## Context

The pinned VLM is approximately 3.09 GB and runs concurrently with an AR
session. A successful weight load is not evidence that production inference
fits reliably.

## Decision

Download the immutable model revision resumably into Application Support,
default to Wi-Fi, and verify every file's length and SHA-256. Admit recovery only
after AR world-tracking support, storage, live-memory preflight, and a
production-shaped 1024×1024 guided warm-up while AR is active. Keep one shared
load task and container, serialize calls, cancel and await generation when the
app backgrounds, and provide no cloud inference fallback.

The plan requested `mlx-swift-lm` 3.31.4 together with
`MLXGuidedGeneration`. ✅ VERIFIED from the upstream package manifests: that tag
does not export that product. Bricky therefore pins immutable commit
`cd1ab3dd98ceb02d095490aa25e61298ea3e2f5b`, the compatible upstream revision
used by this implementation, and excludes `MLXFoundationModels` from its target
graph.

## Consequences

Guide-only use remains available on rejected devices. The shipping memory floor
and admitted-device list remain blocked on physical Instruments measurements.
