import Foundation
import simd

/// The repair suite (M2.4): every sampled step is built one stud off in
/// each direction, judged from two oblique views and one from above, and
/// the planner's repair is checked twice. The actions must undo the shift
/// exactly (anything else is harmful), and the direction told to the user,
/// under each screen rotation, must match where the correction actually
/// moves on screen, found independently by projecting the part's centre
/// through the camera.
extension SyntheticRGBDMain {
    static func runRepair(
        plan: InstructionPlan, renderer: ExpectedDepthRenderer, fixtureStem: String, options: Options
    ) async throws {
        var rng = SplitMix64(seed: options.seed ^ 0x2E9A_1C0D)
        let sourceRoot = URL(fileURLWithPath: options.modelPath).deletingLastPathComponent()
        let geometry = try await PlacementGeometryStore.shared.geometry(
            for: plan, sourceRoot: sourceRoot, partPackRoot: URL(fileURLWithPath: options.ldrawRoot)
        )
        let candidates = plan.steps.indices.filter { !plan.addedPlacements(for: plan.steps[$0]).isEmpty && $0 > 0 }
        let sampled = RecoveryIndexing.evenlySampledIndices(
            count: min(options.sampledSteps, candidates.count), range: 0..<candidates.count
        ).map { candidates[$0] }
        let shifts = [SIMD2(1, 0), SIMD2(-1, 0), SIMD2(0, 1), SIMD2(0, -1)]
        var rows: [String] = []
        var plans = 0

        for stepIndex in sampled {
            let step = plan.steps[stepIndex]
            let completed = geometry.completedSnapshot(before: step)
            let delta = geometry.deltaSnapshot(for: step)
            let scene = SyntheticScene(renderer: renderer, model: geometry.cumulativeSnapshot(through: step), minimumExtent: 0.2)
            let context = RepairPlanner.context(plan: plan, step: step)
            let centre = centroid(delta)
            // The regression views look along diagonals, where every stud-axis
            // correction sits on a sector boundary and is rightly left
            // unworded; near-axis views exercise the oblique wording.
            let views = [
                ("v0", scene.viewPoses[0]), ("front", scene.obliquePose(azimuthDegrees: 12)),
                ("side", scene.obliquePose(azimuthDegrees: 100)), ("top", scene.overheadPose)
            ]
            for shift in shifts {
                let offset = SIMD3<Float>(Float(shift.x) * 0.008, 0, Float(shift.y) * 0.008)
                let physical = InstructionGeometrySnapshot(
                    buffers: completed.buffers + delta.buffers.map { $0.translated(by: offset) }, bounds: nil
                )
                let undo = LatticeOffset(dx: -shift.x, dz: -shift.y)
                let expected = context.added.map { action(.move($0, by: undo)) }
                for (viewLabel, view) in views {
                    let (verdict, _) = try await scene.verify(
                        completed: completed, delta: delta, physical: physical,
                        sensor: SensorModel(rng: &rng), shadow: nil, view: view
                    )
                    let repair = RepairPlanner.plan(verdict: verdict.verdict, context: context)
                    plans += repair == nil ? 0 : 1
                    let produced = repair?.actions ?? []
                    let added = Set(context.added)
                    let harmful = produced.filter { act in
                        guard added.contains(act.target) else { return true }
                        if case .move(_, let by) = act { return by != undo }
                        return true
                    }.count
                    for rotation in ScreenRotation.allCases {
                        let told = repair.flatMap { $0.actions.first }.flatMap { act -> RelativeDirection? in
                            guard case .move(_, let by) = act else { return nil }
                            var stabilizer = DirectionStabilizer()
                            return stabilizer.update(
                                bearing: CameraRelativeDirection.bearingDegrees(
                                    correction: CameraRelativeDirection.worldCorrection(by, worldFromModel: matrix_identity_float4x4),
                                    worldFromCamera: view, rotation: rotation
                                ),
                                pitchDegrees: CameraRelativeDirection.pitchDegrees(worldFromCamera: view),
                                at: 0
                            )
                        }
                        let truth = projectedDirection(
                            from: centre, by: SIMD3(Float(undo.dx) * 0.008, 0, Float(undo.dz) * 0.008),
                            view: view, intrinsics: scene.intrinsics, rotation: rotation
                        )
                        rows.append(try Row.encode([
                            "kind": "repair_plan",
                            "schema_version": 1,
                            "provenance": "synthetic",
                            "fixture_id": "\(fixtureStem)-s\(step.index)-shift\(shift.x)_\(shift.y)-\(viewLabel)-r\(rotation.rawValue)",
                            "verdict": verdict.verdict.evidenceName,
                            "expected_actions": expected,
                            "produced_actions": produced.map(action),
                            "harmful_actions": harmful,
                            "expected_direction": truth?.rawValue ?? "none",
                            "produced_direction": told?.rawValue ?? "none",
                            "screen_rotation": rotation.rawValue,
                        ]))
                    }
                }
            }
        }
        guard !rows.isEmpty else { throw CLIError("no repair rows were generated from \(options.modelPath)") }
        let generated = rows.count
        rows.append(try Row.encode([
            "kind": "synthetic_summary",
            "schema_version": 1,
            "suite": "repair",
            "fixture": fixtureStem,
            "seed": options.seed,
            "steps_sampled": sampled.count,
            "generated_repair_rows": generated,
            "plans_produced": plans,
        ]))
        try rows.joined(separator: "\n").appending("\n")
            .write(toFile: options.outPath, atomically: true, encoding: .utf8)
        print("wrote \(generated) repair rows to \(options.outPath)")
    }

    static func action(_ action: RepairAction) -> [String: Any] {
        var object: [String: Any] = ["action": action.name, "placement": action.target.placement]
        if case .move(_, let by) = action { object["offset"] = [by.dx, by.dz] }
        return object
    }

    static func centroid(_ snapshot: InstructionGeometrySnapshot) -> SIMD3<Float> {
        let points = snapshot.buffers.flatMap(\.positions)
        guard !points.isEmpty else { return .zero }
        return points.reduce(.zero, +) / Float(points.count)
    }

    /// Where `correction` moves `point` on screen, from the camera's own
    /// projection: the independent truth the planner's wording must match.
    /// Nil when the move lands too near a sector boundary to say.
    static func projectedDirection(
        from point: SIMD3<Float>, by correction: SIMD3<Float>, view: simd_float4x4,
        intrinsics: simd_float3x3, rotation: ScreenRotation
    ) -> RelativeDirection? {
        func pixel(_ world: SIMD3<Float>) -> SIMD2<Float> {
            let camera = view.inverse * SIMD4(world, 1)
            let depth = -camera.z
            return SIMD2(
                intrinsics[0][0] * camera.x / depth + intrinsics[2][0],
                -intrinsics[1][1] * camera.y / depth + intrinsics[2][1]
            )
        }
        let delta = pixel(point + correction) - pixel(point)
        // Image right is camera +x, image down is camera −y.
        let cameraVector = SIMD3<Float>(delta.x, -delta.y, 0)
        let axes = rotation.screenAxesInCamera
        let bearing = atan2(simd_dot(cameraVector, axes.right), simd_dot(cameraVector, axes.up)) * 180 / .pi
        guard CameraRelativeDirection.distanceToBoundary(bearing: bearing) > DirectionStabilizer.hysteresisDegrees else {
            return nil
        }
        let topDown = CameraRelativeDirection.pitchDegrees(worldFromCamera: view) > CameraRelativeDirection.topDownEnter
        return CameraRelativeDirection.sector(bearing: bearing, topDown: topDown)
    }
}
