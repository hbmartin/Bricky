import Foundation
import simd

/// Diagnostic for M2.0: renders every step's cumulative geometry twice, from
/// each synthetic view, once colour-merged as existing consumers draw it and
/// once in timeline order as new per-placement code draws it, then counts
/// the depth pixels that differ. Exact depth ties between differently
/// coloured triangles are the only way the two can disagree; this says
/// whether a real fixture has any.
enum RenderOrderCheck {
    static func run(plan: InstructionPlan, engine: LDrawGeometryEngine, renderer: ExpectedDepthRenderer) async throws {
        let segments = try await engine.segmented(placements: plan.placementTimeline)
        let timeline = renderer.prepare(segments)
        var totalDiffering = 0
        var totalPixels = 0
        for step in plan.steps {
            let count = step.cumulativePlacementCount
            let merged = segments.mergedByColour(prefix: count)
            guard !merged.buffers.isEmpty else { continue }
            let scene = SyntheticScene(renderer: renderer, model: merged)
            let colour = renderer.prepare(merged)
            var differing = 0
            for pose in scene.viewPoses {
                let maps = try await renderer.render(
                    [
                        DepthRenderRequest(geometry: colour, viewFromModel: pose.inverse),
                        DepthRenderRequest(geometry: timeline, viewFromModel: pose.inverse, ranges: [segments.vertexRange(0..<count)])
                    ],
                    intrinsics: scene.intrinsics,
                    width: scene.width,
                    height: scene.height
                )
                differing += zip(maps[0].depth, maps[1].depth).reduce(0) { $0 + ($1.0.bitPattern == $1.1.bitPattern ? 0 : 1) }
                totalPixels += maps[0].depth.count
            }
            totalDiffering += differing
            print("RENDER_ORDER step=\(step.index) placements=\(count) differing_pixels=\(differing)")
        }
        print("RENDER_ORDER total differing_pixels=\(totalDiffering) of \(totalPixels)")
    }
}
