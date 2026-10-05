import Foundation
import simd

/// Mid-build states for the synthetic recovery suite (M2.6). The truth is
/// always "step k": the latest step whose placements are present, apart
/// from an explained exception.
enum RecoveryScenarioClass: String, CaseIterable {
    /// Built exactly through step k.
    case exact
    /// Built through step k, but one of step k's own parts is missing.
    case minusPartCurrent = "minus_part_current"
    /// Built through step k, but a part from one of the three steps before
    /// is missing, one nothing rests on: a part forgotten earlier.
    case minusPartEarlier = "minus_part_earlier"
}

struct RecoveryScenario {
    let scenarioClass: RecoveryScenarioClass
    /// Plan index of the true step.
    let stepIndex: Int
    /// The missing placement, if any.
    let missing: Int?

    /// Every scenario the plan supports, with the missing part chosen by
    /// `rng` where there is a choice.
    static func all(plan: InstructionPlan, index: PlacementGeometryIndex, rng: inout SplitMix64) -> [RecoveryScenario] {
        var scenarios: [RecoveryScenario] = []
        for stepIndex in plan.steps.indices {
            let step = plan.steps[stepIndex]
            let built = step.cumulativePlacementCount
            scenarios.append(RecoveryScenario(scenarioClass: .exact, stepIndex: stepIndex, missing: nil))
            let added = Array(plan.addedPlacements(for: step).indices)
            if added.count >= 2 {
                scenarios.append(RecoveryScenario(
                    scenarioClass: .minusPartCurrent, stepIndex: stepIndex,
                    missing: added[Int(rng.next() % UInt64(added.count))]
                ))
            }
            let earlier = (max(0, stepIndex - 3)..<stepIndex).flatMap { Array(plan.addedPlacements(for: plan.steps[$0]).indices) }
                .filter { placement in index.blockers(of: placement).allSatisfy { $0 >= built } }
            if !earlier.isEmpty {
                scenarios.append(RecoveryScenario(
                    scenarioClass: .minusPartEarlier, stepIndex: stepIndex,
                    missing: earlier[Int(rng.next() % UInt64(earlier.count))]
                ))
            }
        }
        return scenarios
    }

    /// The physical build: the step's prefix, without the missing part.
    func physical(_ geometry: PlacementGeometry, plan: InstructionPlan) -> InstructionGeometrySnapshot {
        let built = plan.steps[stepIndex].cumulativePlacementCount
        guard let missing else { return geometry.segments.mergedByColour(prefix: built) }
        return InstructionGeometrySnapshot(
            buffers: geometry.segments.mergedByColour(0..<missing).buffers
                + geometry.segments.mergedByColour((missing + 1)..<built).buffers,
            bounds: nil
        )
    }
}

extension SyntheticRGBDMain {
    /// The recovery suite: the real geometric estimator on rendered,
    /// degraded scenes from its own RNG stream, so arms see identical
    /// frames and ghost placements and pair by fixture.
    static func runRecovery(
        plan: InstructionPlan, renderer: ExpectedDepthRenderer, fixtureStem: String, options: Options
    ) async throws {
        var rng = SplitMix64(seed: options.seed ^ 0x5EC0_7E2A)
        let sourceRoot = URL(fileURLWithPath: options.modelPath).deletingLastPathComponent()
        let partPackRoot = URL(fileURLWithPath: options.ldrawRoot)
        let geometry = try await PlacementGeometryStore.shared.geometry(
            for: plan, sourceRoot: sourceRoot, partPackRoot: partPackRoot
        )
        let scenarios = RecoveryScenario.all(plan: plan, index: geometry.index, rng: &rng)
        var configuration = GeometricRecoveryEstimator.Configuration()
        configuration.consistencyTieBreak = options.recoveryArm == .tiebreak
        var rows: [String] = []
        for scenario in scenarios {
            let step = plan.steps[scenario.stepIndex]
            let scene = SyntheticScene(renderer: renderer, model: geometry.cumulativeSnapshot(through: step))
            var sensor = SensorModel(rng: &rng)
            let frame = try scene.frame(
                of: scenario.physical(geometry, plan: plan), worldFromCamera: scene.viewPoses[0],
                sensor: &sensor, timestamp: 0
            )
            // The user's ghost: within 5 mm and 3° of the truth.
            let perturbation = RegistrationPerturbation(
                label: "ghost",
                x: Float(Int(rng.next() % 11) - 5) * 0.001,
                z: Float(Int(rng.next() % 11) - 5) * 0.001,
                yawDegrees: Float(Int(rng.next() % 7) - 3)
            )
            let estimator = try GeometricRecoveryEstimator(
                frame: frame, sourceRoot: sourceRoot, partPackRoot: partPackRoot,
                configuration: configuration, renderer: renderer, geometry: geometry
            )
            let started = ContinuousClock.now
            let estimate = try await estimator.estimate(
                model: plan, alignment: ARAlignment(id: UUID(), transform: perturbation.pose, isTracking: true), captureIDs: []
            )
            let ranked = estimate?.rankedStepIDs ?? []
            var row: [String: Any] = [
                "kind": "geometric_recovery",
                "schema_version": 1,
                "provenance": "synthetic",
                "fixture_id": "\(fixtureStem)-s\(step.index)-\(scenario.scenarioClass.rawValue)" + (scenario.missing.map { "-p\($0)" } ?? ""),
                "scenario_class": scenario.scenarioClass.rawValue,
                "arm": options.recoveryArm.rawValue,
                "expected_step_id": step.id,
                "expected_step_index": step.index,
                "ranked_step_ids": ranked,
                "certainty": estimate?.certainty.rawValue ?? "insufficient",
                "tie_break_applied": estimate?.modelRevision.hasSuffix("+pcs1") ?? false,
                "estimator_method": "geometric",
                "latency_ms": started.duration(to: .now).milliseconds,
            ]
            if let top = ranked.first, let topStep = plan.steps.first(where: { $0.id == top }) {
                row["top_step_index"] = topStep.index
            }
            rows.append(try Row.encode(row))
        }
        guard !rows.isEmpty else { throw CLIError("no recovery rows were generated from \(options.modelPath)") }
        let generated = rows.count
        rows.append(try Row.encode([
            "kind": "synthetic_summary",
            "schema_version": 1,
            "suite": "recovery",
            "fixture": fixtureStem,
            "seed": options.seed,
            "arm": options.recoveryArm.rawValue,
            "generated_recovery_rows": generated,
        ]))
        try rows.joined(separator: "\n").appending("\n")
            .write(toFile: options.outPath, atomically: true, encoding: .utf8)
        print("wrote \(generated) recovery rows to \(options.outPath)")
    }
}
