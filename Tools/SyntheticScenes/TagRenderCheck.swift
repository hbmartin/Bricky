import Foundation
import simd

/// Gate for M3.1's tag pass, run in CI so the tag shader is compiled and
/// drawn on the macOS runner's GPU, which no other suite does (synthetic
/// scenes carry no colour). For every step's cumulative geometry, from each
/// synthetic view, it checks that:
/// - adding tag passes leaves the depth maps bit-identical;
/// - every tag decodes to a colour the step actually uses;
/// - tag coverage matches depth coverage, within an edge budget.
enum TagRenderCheck {
    /// Separate shader compiles may round triangle edges differently.
    static let coverageBudget = 0.005

    static func run(plan: InstructionPlan, engine: LDrawGeometryEngine, renderer: ExpectedDepthRenderer) async throws {
        let segments = try await engine.segmented(placements: plan.placementTimeline)
        var failures: [String] = []
        var totalCovered = 0
        var totalMismatched = 0
        for step in plan.steps {
            let merged = segments.mergedByColour(prefix: step.cumulativePlacementCount)
            guard !merged.buffers.isEmpty else { continue }
            let scene = SyntheticScene(renderer: renderer, model: merged)
            let plain = renderer.prepare(merged)
            let tagged = renderer.prepare(merged, tagged: true)
            let codes = Set(merged.buffers.map(\.colorCode))
            var stepCovered = 0
            var stepMismatched = 0
            for pose in scene.viewPoses {
                let request = DepthRenderRequest(geometry: plain, viewFromModel: pose.inverse)
                let tagRequest = DepthRenderRequest(geometry: tagged, viewFromModel: pose.inverse)
                let alone = try await renderer.render(
                    [request], intrinsics: scene.intrinsics, width: scene.width, height: scene.height
                )
                let mixed = try await renderer.render(
                    [request], tags: [tagRequest], intrinsics: scene.intrinsics, width: scene.width, height: scene.height
                )
                if alone[0].depth.map(\.bitPattern) != mixed.depth[0].depth.map(\.bitPattern) {
                    failures.append("step \(step.index): depth changed beside a tag pass")
                }
                let tags = mixed.tags[0]
                let foreign = Set(tags.tags.indices.compactMap { tags.colourCode(at: $0) }).subtracting(codes)
                if !foreign.isEmpty {
                    failures.append("step \(step.index): tags decode to unused colours \(foreign.sorted())")
                }
                let coverage = Self.coverage(depth: mixed.depth[0].depth, tags: tags.tags)
                stepCovered += coverage.covered
                stepMismatched += coverage.mismatched
            }
            totalCovered += stepCovered
            totalMismatched += stepMismatched
            print("TAG_RENDER step=\(step.index) colours=\(codes.count) covered=\(stepCovered) mismatched=\(stepMismatched)")
        }
        let fraction = totalCovered > 0 ? Double(totalMismatched) / Double(totalCovered) : 0
        print("TAG_RENDER total covered=\(totalCovered) mismatched=\(totalMismatched) fraction=\(fraction)")
        if fraction > coverageBudget {
            failures.append("coverage mismatch \(fraction) exceeds \(coverageBudget)")
        }
        guard failures.isEmpty else {
            throw CLIError("tag render check failed:\n" + failures.joined(separator: "\n"))
        }
    }

    private static func coverage(depth: [Float32], tags: [UInt32]) -> (covered: Int, mismatched: Int) {
        var covered = 0
        var mismatched = 0
        for index in depth.indices {
            let hasDepth = depth[index] > 0
            let hasTag = tags[index] != 0
            if hasDepth { covered += 1 }
            if hasDepth != hasTag { mismatched += 1 }
        }
        return (covered, mismatched)
    }
}
