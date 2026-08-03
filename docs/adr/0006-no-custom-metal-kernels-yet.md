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

## Consequences

The `apple-metal-tensorops` review does not cause speculative kernel work. The
decision can be revisited with measured evidence from the production recovery
benchmark.
