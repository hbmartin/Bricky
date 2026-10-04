import os

/// Signpost intervals for the geometry stack, visible in Instruments'
/// os_signpost track (subsystem `com.bricky.app`, category `Geometry`).
/// They exist so the Phase 1 device traces can attribute time between
/// rendering, ICP, snapshot building, and surface sampling before anything
/// is parallelized or moved to the GPU (ADR 0006: profile first).
enum GeometrySignposts {
    static let signposter = OSSignposter(subsystem: "com.bricky.app", category: "Geometry")
}
