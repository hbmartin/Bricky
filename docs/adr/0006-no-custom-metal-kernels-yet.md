# ADR 0006: Do not add custom Metal TensorOps without profiling evidence

- Status: Accepted
- Date: 2026-08-02

## Context

Custom kernels add numerical, memory-lifetime, device-support, and maintenance
risk. The current recovery path uses supported MLX operations and has not yet
been profiled on the candidate physical-device matrix.

## Decision

Use MLX Swift primitives for v1. Add a custom Metal or TensorOps kernel only if
Instruments identifies a stable, material bottleneck, a written benchmark
defines numerical tolerances and representative shapes, and the kernel improves
end-to-end latency or peak memory on admitted devices without regressions.

Amended 2026-08-03: the same discipline extends to registration compute — the
depth-ICP solver (ADR 0009) stays on CPU/simd until profiling proves
otherwise. The one permitted Metal addition is the shared expected-depth
raster render pass, which is an ordinary render pipeline, not a compute
kernel, and is required for correctness (RealityKit exposes no depth
readback), not speed.

## Consequences

The `apple-metal-tensorops` review does not cause speculative kernel work. The
decision can be revisited with measured evidence from the production recovery
benchmark.
