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
        let crossStep = try crossStepRows(plan: plan, geometry: geometry, sampled: sampled, fixtureStem: fixtureStem)
        rows += crossStep.rows
        rows.append(try Row.encode([
            "kind": "synthetic_summary",
            "schema_version": 1,
            "suite": "repair",
            "fixture": fixtureStem,
            "seed": options.seed,
            "steps_sampled": sampled.count,
            "generated_repair_rows": generated,
            "plans_produced": plans,
            "generated_cross_step_rows": crossStep.rows.count,
            "cross_step_plans": crossStep.plans,
            "cross_step_withheld": crossStep.withheld,
        ]))
        try rows.joined(separator: "\n").appending("\n")
            .write(toFile: options.outPath, atomically: true, encoding: .utf8)
        print("wrote \(generated) in-step and \(crossStep.rows.count) cross-step repair rows to \(options.outPath)")
    }

    /// Cross-step plans (M2.9; the flag is on only here and in tests). For
    /// each sampled step, the earlier part with the most parts resting on it
    /// within budget is shifted, turned, missing, and missing under parts
    /// seen in place; the part with the most beyond budget is shifted.
    /// Pure support-graph work: no renders and no random draws, so the
    /// in-step rows are unchanged. Each plan is replayed on the support
    /// graph, and any step a builder could not do, or that leaves the build
    /// different from authored, is harmful.
    static func crossStepRows(
        plan: InstructionPlan, geometry: PlacementGeometry, sampled: [Int], fixtureStem: String
    ) throws -> (rows: [String], plans: Int, withheld: Int) {
        let index = geometry.index
        let budget = CrossStepRepairPlanner.defaultBudget
        var rows: [String] = []
        var plans = 0
        var withheld = 0
        for stepIndex in sampled {
            let step = plan.steps[stepIndex]
            let built = step.cumulativePlacementCount
            let ranked = (0..<step.addedPlacementRange.lowerBound)
                .map { (placement: $0, resting: index.blockers(of: $0).filter { $0 < built }) }
                .filter { !$0.resting.isEmpty }
                .sorted { $0.resting.count != $1.resting.count ? $0.resting.count > $1.resting.count : $0.placement < $1.placement }
            var cases: [(label: String, placement: Int, state: PlacementState, observed: [Int])] = []
            if let within = ranked.first(where: { $0.resting.count <= budget }) {
                cases += [
                    ("shift", within.placement, .displaced(LatticeOffset(dx: 1)), []),
                    ("turn", within.placement, .rotated(quarterTurns: 1), []),
                    ("missing", within.placement, .absent, []),
                    ("missing_under_present", within.placement, .absent, within.resting),
                ]
            }
            if let beyond = ranked.first(where: { $0.resting.count > budget }) {
                cases.append(("shift_over_budget", beyond.placement, .displaced(LatticeOffset(dx: 1)), []))
            }
            for item in cases {
                let anomaly = PlacementObservation(placement: item.placement, state: item.state, evidence: PlacementEvidence())
                let observed = item.observed.map { PlacementObservation(placement: $0, state: .present, evidence: PlacementEvidence()) }
                let repair = CrossStepRepairPlanner.plan(
                    anomaly: anomaly, observed: observed, index: index, plan: plan,
                    currentStepID: step.id, built: built, flags: RepairFeatureFlags(crossStep: true)
                )
                let produced = repair?.actions ?? []
                plans += produced.isEmpty ? 0 : 1
                withheld += repair?.withheld.isEmpty == false ? 1 : 0
                let expected = expectedCrossStep(anomaly: anomaly, observed: Set(item.observed), index: index, built: built, budget: budget)
                rows.append(try Row.encode([
                    "kind": "repair_plan",
                    "schema_version": 1,
                    "provenance": "synthetic",
                    "fixture_id": "\(fixtureStem)-s\(step.index)-xstep-p\(item.placement)-\(item.label)",
                    "scope": "cross_step",
                    "verdict": "cross_step",
                    "expected_actions": expected,
                    "produced_actions": produced.map(action),
                    "withheld": (repair?.withheld ?? []).map(\.reason.rawValue),
                    "harmful_actions": crossStepHarm(produced, anomaly: anomaly, index: index, built: built),
                    "expected_direction": "none",
                    "produced_direction": "none",
                ]))
            }
        }
        return (rows, plans, withheld)
    }

    /// The plan a careful builder would follow, found by taking off whatever
    /// is on top first (highest authored index among the free parts), then
    /// putting parts back lowest first. Empty where nothing should be asked.
    static func expectedCrossStep(
        anomaly: PlacementObservation, observed: Set<Int>, index: PlacementGeometryIndex, built: Int, budget: Int
    ) -> [[String: Any]] {
        let resting = Set(index.blockers(of: anomaly.placement).filter { $0 < built })
        if anomaly.state == .absent, !resting.isDisjoint(with: observed) { return [] }
        guard resting.count <= budget else { return [] }
        var onBuild = resting
        var removed: [Int] = []
        while let free = onBuild.filter({ part in index.supports[part].allSatisfy { !onBuild.contains($0) } }).max() {
            onBuild.remove(free)
            removed.append(free)
        }
        func entry(_ name: String, _ placement: Int) -> [String: Any] { ["action": name, "placement": placement] }
        var fix = entry(anomaly.state == .absent ? "add" : "move", anomaly.placement)
        switch anomaly.state {
        case .displaced(let offset): fix["offset"] = [-offset.dx, -offset.dz]
        case .rotated: fix["action"] = "rotate"
        default: break
        }
        return removed.map { entry("remove", $0) } + [fix] + removed.sorted().map { entry("re_add", $0) }
    }

    /// Replays a cross-step plan on the support graph. Harmful: touching a
    /// part that neither is the problem nor rests on it, taking off a part
    /// with something still on it, fixing the part under something,
    /// a fix that does not undo the finding, putting a part back with no
    /// support, and a plan that leaves the build different from authored.
    static func crossStepHarm(
        _ actions: [RepairAction], anomaly: PlacementObservation, index: PlacementGeometryIndex, built: Int
    ) -> Int {
        guard !actions.isEmpty else { return 0 }
        let allowed = Set(index.blockers(of: anomaly.placement)).union([anomaly.placement])
        var onBuild = Set(0..<built)
        if anomaly.state == .absent { onBuild.remove(anomaly.placement) }
        var fixed = false
        var harm = 0
        for act in actions {
            let part = act.target.placement
            guard allowed.contains(part) else {
                harm += 1
                continue
            }
            let covered = index.supports[part].contains(where: onBuild.contains)
            switch act {
            case .remove:
                if !onBuild.contains(part) || covered { harm += 1 }
                onBuild.remove(part)
            case .reAdd:
                let support = index.supportedBy[part].filter { $0 < built }
                if onBuild.contains(part) || !support.allSatisfy(onBuild.contains) { harm += 1 }
                onBuild.insert(part)
            case .add, .move, .rotate:
                let undoes: Bool
                switch (act, anomaly.state) {
                case (.add, .absent): undoes = true
                case (.move(_, let by), .displaced(let offset)): undoes = by.dx == -offset.dx && by.dz == -offset.dz
                case (.rotate(_, let turns), .rotated(let found)): undoes = ((turns + found) % 4 + 4) % 4 == 0
                default: undoes = false
                }
                if part != anomaly.placement || covered || !undoes || fixed { harm += 1 }
                fixed = true
                onBuild.insert(part)
            case .swapColour:
                harm += 1
            }
        }
        if !fixed || onBuild != Set(0..<built) { harm += 1 }
        return harm
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
