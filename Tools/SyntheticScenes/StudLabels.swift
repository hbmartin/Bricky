import Foundation
import simd

/// Stud labels from geometry alone (iOS 27 Phase 4, ADR 0020): where each
/// top stud's keypoint lands in a view, and whether the view can see it.
/// No image is written and no colour is invented (ADR 0008, ADR 0014):
/// these rows say where studs are, for real photos to be labelled against
/// later.
enum StudLabels {
    static let kind = "stud_labels"
    /// Labels are drawn at photo-like resolution, four times the depth grid.
    static let labelScale = 4
    /// Parts whose top-stud counts the check pins, from the pinned pack.
    static let knownTopStuds: [(part: String, studs: Int)] = [
        ("3001.dat", 8), ("3003.dat", 4), ("3004.dat", 2), ("3020.dat", 8), ("3039.dat", 2),
    ]

    private static func intrinsics(scale: Int) -> simd_float3x3 {
        var matrix = matrix_identity_float3x3
        matrix[0][0] = 210 * Float(scale)
        matrix[1][1] = 210 * Float(scale)
        matrix[2][0] = 128 * Float(scale)
        matrix[2][1] = 96 * Float(scale)
        return matrix
    }

    /// Renders depth and stud ids for the cumulative build through `step`
    /// from `pose`, at `scale` times the depth grid.
    private static func render(
        step: AuthoredStep, segments: SegmentedGeometry, renderer: ExpectedDepthRenderer,
        plain: DepthGeometry, studTagged: DepthGeometry, pose: simd_float4x4, scale: Int
    ) async throws -> (depth: ExpectedDepthMap, ids: ExpectedTagMap, alone: ExpectedDepthMap) {
        let ranges = [segments.vertexRange(0..<step.cumulativePlacementCount)]
        let request = DepthRenderRequest(geometry: plain, viewFromModel: pose.inverse, ranges: ranges)
        let tagRequest = DepthRenderRequest(geometry: studTagged, viewFromModel: pose.inverse, ranges: ranges)
        let width = 256 * scale
        let height = 192 * scale
        let alone = try await renderer.render([request], intrinsics: intrinsics(scale: scale), width: width, height: height)
        let mixed = try await renderer.render(
            [request], tags: [tagRequest], intrinsics: intrinsics(scale: scale), width: width, height: height
        )
        return (mixed.depth[0], mixed.tags[0], alone[0])
    }

    /// `--export-stud-labels`: one row per step and view, every top stud
    /// the build has so far.
    static func export(plan: InstructionPlan, engine: LDrawGeometryEngine, renderer: ExpectedDepthRenderer,
                       fixtureStem: String, outPath: String) async throws {
        let (segments, index) = try await engine.segmentedWithStuds(placements: plan.placementTimeline)
        let plain = renderer.prepare(segments)
        let studTagged = renderer.prepare(segments, triangleTags: index.triangleStud)
        var rows: [String] = []
        for step in plan.steps {
            let full = segments.mergedByColour(prefix: step.cumulativePlacementCount)
            guard !full.buffers.isEmpty else { continue }
            let scene = SyntheticScene(renderer: renderer, model: full)
            let studs = index.studs.indices.filter {
                index.studs[$0].role == .top && index.studs[$0].placement < step.cumulativePlacementCount
            }
            for (view, pose) in (scene.viewPoses + [scene.overheadPose]).enumerated() {
                let maps = try await render(
                    step: step, segments: segments, renderer: renderer, plain: plain, studTagged: studTagged,
                    pose: pose, scale: labelScale
                )
                let labels = StudVisibility.labels(
                    index: index, studs: studs, viewFromModel: pose.inverse, intrinsics: intrinsics(scale: labelScale),
                    ids: maps.ids.tags, depth: maps.depth.depth, width: maps.depth.width, height: maps.depth.height
                )
                let entries: [[String: Any]] = labels.map { label in
                    let stud = index.studs[label.stud]
                    return [
                        "stud": label.stud, "placement": stud.placement, "primitive": stud.primitive,
                        "u": Double(label.u), "v": Double(label.v), "depth_m": Double(label.depth),
                        "pixels": label.pixels, "up_facing": label.upFacing, "visible": label.visible,
                        "scaled": stud.isScaled,
                    ]
                }
                rows.append(try Row.encode([
                    "kind": kind,
                    "provenance": "synthetic",
                    "schema_version": 1,
                    "fixture_id": "\(fixtureStem)-s\(step.index)-v\(view)",
                    "step_index": step.index,
                    "view": view,
                    "width": maps.depth.width,
                    "height": maps.depth.height,
                    "studs": entries,
                ]))
            }
        }
        try (rows.joined(separator: "\n") + (rows.isEmpty ? "" : "\n")).write(toFile: outPath, atomically: true, encoding: .utf8)
        print("wrote \(rows.count) stud_labels rows to \(outPath)")
    }

    /// `--check-stud-labels`, the CI gate for the stud tag pass and catalog.
    static func check(plan: InstructionPlan, engine: LDrawGeometryEngine, renderer: ExpectedDepthRenderer,
                      partPackRoot: URL) async throws {
        var failures: [String] = []
        let (segments, index) = try await engine.segmentedWithStuds(placements: plan.placementTimeline)
        let plain = renderer.prepare(segments)
        let studTagged = renderer.prepare(segments, triangleTags: index.triangleStud)
        var visibleTotal = 0
        for step in plan.steps {
            let full = segments.mergedByColour(prefix: step.cumulativePlacementCount)
            guard !full.buffers.isEmpty else { continue }
            let scene = SyntheticScene(renderer: renderer, model: full)
            let studs = index.studs.indices.filter {
                index.studs[$0].role == .top && index.studs[$0].placement < step.cumulativePlacementCount
            }
            var stepVisible = 0
            for pose in scene.viewPoses + [scene.overheadPose] {
                let maps = try await render(
                    step: step, segments: segments, renderer: renderer, plain: plain, studTagged: studTagged,
                    pose: pose, scale: 1
                )
                if maps.alone.depth.map(\.bitPattern) != maps.depth.depth.map(\.bitPattern) {
                    failures.append("step \(step.index): depth changed beside the stud pass")
                }
                if let stray = maps.ids.tags.first(where: { $0 > UInt32(index.studs.count) }) {
                    failures.append("step \(step.index): id \(stray) names no stud")
                }
                failures += projectionDisagreements(
                    index: index, studs: studs, pose: pose, ids: maps.ids, step: step.index
                )
                stepVisible += StudVisibility.labels(
                    index: index, studs: studs, viewFromModel: pose.inverse, intrinsics: intrinsics(scale: 1),
                    ids: maps.ids.tags, depth: maps.depth.depth, width: maps.depth.width, height: maps.depth.height
                ).filter(\.visible).count
            }
            visibleTotal += stepVisible
            print("STUD_LABELS step=\(step.index) top_studs=\(studs.count) visible_labels=\(stepVisible)")
        }
        failures += unclassifiedPrimitives(partPackRoot: partPackRoot)
        for (part, expected) in knownTopStuds {
            let placement = PartPlacement(
                id: part, partReference: part, colorCode: 4, transform: .identity,
                sourceSection: "check", sourceLine: 0, isSubmodelReference: false
            )
            let (_, studs) = try await engine.segmentedWithStuds(placements: [placement])
            let top = studs.studs.filter { $0.role == .top && !$0.isScaled }.count
            print("STUD_LABELS part=\(part) top_studs=\(top)")
            if top != expected { failures.append("\(part) has \(top) top studs, expected \(expected)") }
        }
        print("STUD_LABELS total studs=\(index.studs.count) top=\(index.topStuds.count) visible_labels=\(visibleTotal)")
        guard failures.isEmpty else {
            throw CLIError("stud label check failed:\n" + failures.joined(separator: "\n"))
        }
    }

    /// A stud whose id is on screen must project inside its own pixels
    /// (with a 2-pixel margin): the CPU projection and the rasterizer agree.
    private static func projectionDisagreements(
        index: StudIndex, studs: [Int], pose: simd_float4x4, ids: ExpectedTagMap, step: Int
    ) -> [String] {
        var boxes: [UInt32: (minX: Int, minY: Int, maxX: Int, maxY: Int)] = [:]
        for y in 0..<ids.height {
            for x in 0..<ids.width {
                let id = ids.tags[y * ids.width + x]
                guard id != 0 else { continue }
                let box = boxes[id] ?? (x, y, x, y)
                boxes[id] = (min(box.minX, x), min(box.minY, y), max(box.maxX, x), max(box.maxY, y))
            }
        }
        var failures: [String] = []
        for ordinal in studs {
            guard let box = boxes[UInt32(ordinal + 1)],
                  let projected = StudProjection.project(
                    index.studs[ordinal].keypoint, viewFromModel: pose.inverse, intrinsics: intrinsics(scale: 1)
                  ) else { continue }
            let inside = projected.u >= Float(box.minX - 2) && projected.u <= Float(box.maxX + 3)
                && projected.v >= Float(box.minY - 2) && projected.v <= Float(box.maxY + 3)
            if !inside {
                failures.append("step \(step): stud \(ordinal) projects to (\(projected.u), \(projected.v)) outside its pixels \(box)")
            }
        }
        return failures
    }

    /// Every stud-like primitive in the pinned pack must have a catalog
    /// entry, so a stud is never silently skipped or guessed at.
    private static func unclassifiedPrimitives(partPackRoot: URL) -> [String] {
        var unclassified: [String] = []
        var seen = 0
        for folder in ["p", "p/8", "p/48"] {
            let directory = partPackRoot.appendingPathComponent(folder)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { continue }
            for name in names.sorted() where name.lowercased().hasPrefix("stu") && name.lowercased().hasSuffix(".dat") {
                seen += 1
                if StudPrimitiveCatalog.kind(of: name) == nil { unclassified.append("\(folder)/\(name)") }
            }
        }
        print("STUD_LABELS catalog primitives=\(seen) unclassified=\(unclassified.count)")
        return unclassified.isEmpty ? [] : ["unclassified stud primitives: \(unclassified.joined(separator: ", "))"]
    }
}
