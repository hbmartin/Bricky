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

Amended 2026-09-25: the expected-depth pass may be one shared instance per
process and may render several hypotheses per command buffer — as
sequential passes, layered render targets, or instanced draws — because
that remains an ordinary vertex/fragment render pipeline; no compute kernel
is admitted by this amendment. The shared renderer uploads each snapshot's
vertices once, pools its render targets, and completes batches
asynchronously; its batches are bit-identical to single renders. Geometry
signposts (`com.bricky.app` / `Geometry`) exist so the device profiling
this ADR demands can attribute time before anything else moves to the GPU.

## Consequences

The `apple-metal-tensorops` review does not cause speculative kernel work. The
decision can be revisited with measured evidence from the production recovery
benchmark.
