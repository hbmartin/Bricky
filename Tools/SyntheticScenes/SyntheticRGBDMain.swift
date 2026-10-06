import Foundation
import simd

/// Generates synthetic RGB-D evaluation rows from a stepped LDraw model:
/// per-step scenes with injected placement errors, rendered through the SAME
/// `ExpectedDepthRenderer` the app uses (one depth code path, so evaluation
/// measures the solver and verifier, not renderer disagreement), degraded by
/// a deterministic LiDAR sensor model, then pushed through the depth-ICP
/// solver and the geometric verifier. Output is NDJSON for
/// `Tools/RecoveryEvaluation/score_results.py` (kinds: registration,
/// verification).
///
/// The sensor model constants are RECONSTRUCTED until calibrated against
/// real captures of a known build (CONTEXT.md release gates).
///
/// Calibration status: the bundled synthetic-tower smoke fixture is
/// deliberately hard (self-similar studless-scale cubes at LiDAR resolution)
/// and currently fails the registration gates while passing verification
/// with zero false-completes. The real-tower fixture (real parts, pinned
/// pack required) established two findings on the RECONSTRUCTED sensor
/// model: uniformly tiled brick layers alias along the stud lattice (the
/// solve walks ~one pitch per frame at margin ≈ 1.0 — release-corpus
/// models need tall multi-brick massing, which stops the walk), and the
/// remaining blocker is a per-view systematic bias of ~15 mm from the
/// reconstructed edge dilation/dropout that alternating-view blending
/// cannot cancel. That bias must be calibrated against real device
/// captures before the gates can go green — tuning solver constants to a
/// possibly-fictional edge model would be fitting noise. False-complete
/// stays 0.0 on every fixture; under-confidence (uncertain-on-correct)
/// is the failure direction, which is the safe side of ADR 0008.
/// BRICKY_SYNTH_DEBUG=1 prints per-frame solve quality for this work.
@main
struct SyntheticRGBDMain {
    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    enum Suite: String {
        /// The committed regression corpus: registration sweep plus the
        /// verification taxonomy on sampled steps.
        case regression
        /// Mistake classes the taxonomy lacks, on every single-part step.
        case challenge
        /// Repair plans and their camera-relative wording (M2.4).
        case repair
        /// Geometric recovery on mid-build states (M2.6).
        case recovery
        /// Suggested ghost placement on and off the build (M2.7).
        case placement
    }

    /// Which recovery configuration the suite runs: the control, or the
    /// placement-consistency tie-break (M2.6).
    enum RecoveryArm: String {
        case control
        case tiebreak
    }

    struct Options {
        var modelPath: String
        var ldrawRoot: String
        var outPath: String
        var seed: UInt64 = 42
        var sampledSteps = 6
        var suite = Suite.regression
        /// Replays an evidence bundle's verification windows instead of
        /// generating synthetic scenes.
        var replayBundle: String?
        var replayJudge = WindowReplay.Judge.verifier
        /// The colour term's mode for replayed windows (M3.2); nil leaves
        /// the judge depth-only, as the device ran before the term existed.
        var colourTerm: ColourTermMode?
        var recoveryArm = RecoveryArm.control
        /// Prints colour-order vs timeline-order render differences per step
        /// and exits (M2.0 diagnostic).
        var checkRenderOrder = false
        var checkTagRender = false
    }

    static func parseOptions() throws -> Options {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard let modelPath = arguments.first, !modelPath.hasPrefix("--") else {
            throw CLIError("usage: SyntheticRGBD <model.mpd|.ldr> --ldraw-root <dir> --out <results.ndjson> [--seed N] [--steps N] [--suite regression|challenge|repair|placement|recovery [--recovery-arm control|tiebreak]] [--replay-bundle <unzipped bundle> [--judge verifier|diff] [--colour-term off|shadow|block|full]] [--check-render-order] [--check-tag-render]")
        }
        arguments.removeFirst()
        var options = Options(modelPath: modelPath, ldrawRoot: "", outPath: "")
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            if flag == "--check-render-order" {
                options.checkRenderOrder = true
                index += 1
                continue
            }
            if flag == "--check-tag-render" {
                options.checkTagRender = true
                index += 1
                continue
            }
            guard index + 1 < arguments.count else { throw CLIError("missing value for \(flag)") }
            let value = arguments[index + 1]
            switch flag {
            case "--ldraw-root": options.ldrawRoot = value
            case "--out": options.outPath = value
            case "--seed":
                guard let seed = UInt64(value) else { throw CLIError("invalid value for --seed: \(value)") }
                options.seed = seed
            case "--steps":
                guard let steps = Int(value) else { throw CLIError("invalid value for --steps: \(value)") }
                options.sampledSteps = max(1, steps)
            case "--suite":
                guard let suite = Suite(rawValue: value) else { throw CLIError("invalid value for --suite: \(value)") }
                options.suite = suite
            case "--replay-bundle": options.replayBundle = value
            case "--recovery-arm":
                guard let arm = RecoveryArm(rawValue: value) else { throw CLIError("invalid value for --recovery-arm: \(value)") }
                options.recoveryArm = arm
            case "--judge":
                guard let judge = WindowReplay.Judge(rawValue: value) else { throw CLIError("invalid value for --judge: \(value)") }
                options.replayJudge = judge
            case "--colour-term":
                guard let mode = ColourTermMode(rawValue: value == "block" ? ColourTermMode.blockOnly.rawValue : value) else {
                    throw CLIError("invalid value for --colour-term: \(value)")
                }
                options.colourTerm = mode
            default: throw CLIError("unknown flag \(flag)")
            }
            index += 2
        }
        guard !options.ldrawRoot.isEmpty, !options.outPath.isEmpty else {
            throw CLIError("--ldraw-root and --out are required")
        }
        // Synthetic scenes carry no colour, and none may be invented
        // (ADR 0008, ADR 0014): the colour term only replays real windows.
        if options.colourTerm != nil, options.replayBundle == nil {
            throw CLIError("--colour-term needs --replay-bundle: synthetic scenes have no colour")
        }
        return options
    }

    static func run() async throws {
        let options = try parseOptions()
        let modelURL = URL(fileURLWithPath: options.modelPath)
        let fixtureStem = modelURL.deletingPathExtension().lastPathComponent
        // Folder-import semantics: the root plus its sibling .ldr/.dat custom
        // files form the source closure, and the same directory doubles as
        // the geometry engine's source root.
        let sourceDirectory = modelURL.deletingLastPathComponent()
        let siblingNames = try FileManager.default.contentsOfDirectory(atPath: sourceDirectory.path)
            .filter { ["ldr", "dat", "mpd"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
            .sorted()
        let sourceFiles = try siblingNames.map { name in
            InstructionSourceFile(
                relativePath: name,
                data: try Data(contentsOf: sourceDirectory.appendingPathComponent(name))
            )
        }
        let document = try LDrawInstructionParser().parse(
            files: sourceFiles,
            rootRelativePath: modelURL.lastPathComponent
        )
        let plan = try InstructionPlanBuilder().build(
            document: document,
            title: fixtureStem,
            sourceFilename: modelURL.lastPathComponent,
            sourceSHA256: "synthetic"
        )
        let engine = LDrawGeometryEngine(
            sourceRoot: modelURL.deletingLastPathComponent(),
            partPackRoot: URL(fileURLWithPath: options.ldrawRoot)
        )
        let renderer = try ExpectedDepthRenderer()
        if options.checkRenderOrder {
            try await RenderOrderCheck.run(plan: plan, engine: engine, renderer: renderer)
            return
        }
        if options.checkTagRender {
            try await TagRenderCheck.run(plan: plan, engine: engine, renderer: renderer)
            return
        }
        if let bundle = options.replayBundle {
            // The model's directory must hold exactly the files that were
            // imported, so its identity matches the bundle's sessions.
            let (rows, summary) = try await WindowReplay.run(
                bundle: URL(fileURLWithPath: bundle),
                plan: plan,
                sourceIdentity: InstructionSourceIdentity.sha256(of: sourceFiles),
                geometry: try await PlacementGeometryStore.shared.geometry(
                    for: plan, sourceRoot: sourceDirectory, partPackRoot: URL(fileURLWithPath: options.ldrawRoot)
                ),
                renderer: renderer,
                judge: options.replayJudge,
                colourTerm: options.colourTerm,
                colourTable: ColourTable(definitions: try LDConfigPalette.load(libraryURL: URL(fileURLWithPath: options.ldrawRoot)))
            )
            try (rows.joined(separator: "\n") + (rows.isEmpty ? "" : "\n"))
                .write(toFile: options.outPath, atomically: true, encoding: .utf8)
            print("replayed \(summary.replayed)/\(summary.windows) windows; \(summary.matches) match the device verdict; \(summary.skippedSessions) sessions skipped; wrote \(rows.count) staged rows")
            return
        }
        if options.suite == .placement {
            try await runPlacementSuggestion(plan: plan, renderer: renderer, fixtureStem: fixtureStem, options: options)
            return
        }
        if options.suite == .recovery {
            try await runRecovery(plan: plan, renderer: renderer, fixtureStem: fixtureStem, options: options)
            return
        }
        if options.suite == .repair {
            try await runRepair(plan: plan, renderer: renderer, fixtureStem: fixtureStem, options: options)
            return
        }
        if options.suite == .challenge {
            try await runChallenge(
                plan: plan, engine: engine, renderer: renderer, fixtureStem: fixtureStem, options: options
            )
            return
        }
        var rng = SplitMix64(seed: options.seed)
        var rows: [String] = []
        var registrationRows = 0
        var verificationRows = 0
        var droppedByDetectability: [String: Int] = [:]
        // The shadow build diff (M2.3) judges the same frames; its rows go
        // after the regression rows so those stay byte-identical.
        var placementRows: [String] = []
        var judgeDisagreements = 0

        let stepIndices = RecoveryIndexing.evenlySampledIndices(
            count: min(options.sampledSteps, plan.steps.count),
            range: 0..<plan.steps.count
        )

        // One flatten for the corpus; each step's geometry is a range of it,
        // identical to a per-step snapshot (M2.0).
        let geometry = try await PlacementGeometryStore.shared.geometry(
            for: plan, sourceRoot: sourceDirectory, partPackRoot: URL(fileURLWithPath: options.ldrawRoot)
        )
        for stepIndex in stepIndices {
            let step = plan.steps[stepIndex]
            let completed = geometry.completedSnapshot(before: step)
            let delta = geometry.deltaSnapshot(for: step)
            let full = geometry.cumulativeSnapshot(through: step)
            guard !full.buffers.isEmpty else { continue }

            let scene = SyntheticScene(renderer: renderer, model: full)

            // Registration sweep on the full build: perturbed inits, solved
            // over two viewpoints like the product's actual geometry.
            for perturbation in RegistrationPerturbation.sweep {
                let outcome = try scene.solveRegistration(
                    perturbation: perturbation,
                    sensor: SensorModel(rng: &rng)
                )
                rows.append(try Row.registration(
                    fixture: "\(fixtureStem)-s\(stepIndex)-\(perturbation.label)",
                    ambiguityExpected: perturbation.ambiguityExpected,
                    outcome: outcome
                ))
                registrationRows += 1
            }

            // Verification scenarios: the physical scene carries the injected
            // error, the verifier judges the authored delta.
            let stepGeometry = StepGeometry(step: step, geometry: geometry)
            for scenario in VerificationScenario.taxonomy {
                let physical = scenario.physicalSnapshot(completed: completed, delta: delta)
                let authoredCompleted = scenario.authoredCompleted(completed: completed, delta: delta)
                let started = ContinuousClock.now
                let (verdict, shadow) = try await scene.verify(
                    completed: authoredCompleted,
                    delta: delta,
                    physical: physical,
                    sensor: SensorModel(rng: &rng),
                    shadow: (try BuildDiffEngine(renderer: renderer), StepGeometry(
                        completedSnapshot: authoredCompleted, deltaSnapshot: delta,
                        segments: stepGeometry.segments, index: stepGeometry.index,
                        completedPlacements: stepGeometry.completedPlacements, deltaPlacements: stepGeometry.deltaPlacements
                    ))
                )
                let verifierMilliseconds = started.duration(to: .now).milliseconds - (shadow?.milliseconds ?? 0)
                if let shadow {
                    if !Row.sameAssessment(shadow.verdict, verdict) { judgeDisagreements += 1 }
                    if let diff = shadow.diff {
                        placementRows += try Row.placements(
                            fixture: "\(fixtureStem)-s\(stepIndex)-\(scenario.label)",
                            diff: diff,
                            plan: plan,
                            expected: { _ in scenario.expectedPlacement },
                            detectability: verdict.detectability,
                            latencyMilliseconds: shadow.milliseconds
                        )
                    }
                }
                // An expected-complete row whose delta the verifier itself
                // rates below strong is not a fair recall target: the honest
                // response to a weakly visible delta is abstention (ADR 0008),
                // so such rows would punish correct behavior. Every other
                // scenario keeps its row regardless of detectability. Drops
                // are counted into the summary row, where the regression
                // baseline guards them: a verifier change that downgrades
                // detectability would otherwise delete its own recall
                // failures and read as an improvement.
                if scenario.expectedVerdict == "complete", verdict.detectability != .strong {
                    droppedByDetectability[verdict.detectability.rawValue, default: 0] += 1
                    continue
                }
                rows.append(try Row.verification(
                    fixture: "\(fixtureStem)-s\(stepIndex)-\(scenario.label)",
                    expected: scenario.expectedVerdict,
                    verification: verdict,
                    latencyMilliseconds: verifierMilliseconds
                ))
                verificationRows += 1
            }
        }

        guard !rows.isEmpty else {
            throw CLIError("no benchmark rows were generated from \(options.modelPath)")
        }
        rows.append(try Row.encode([
            "kind": "synthetic_summary",
            "schema_version": 1,
            "suite": "regression",
            "fixture": fixtureStem,
            "seed": options.seed,
            "steps_sampled": stepIndices.count,
            "generated_registration_rows": registrationRows,
            "generated_verification_rows": verificationRows,
            "dropped_expected_complete_below_strong": droppedByDetectability.values.reduce(0, +),
            "dropped_by_detectability": droppedByDetectability,
        ]))
        rows += placementRows
        rows.append(try Row.encode([
            "kind": "synthetic_summary",
            "schema_version": 1,
            "suite": "placement",
            "fixture": fixtureStem,
            "seed": options.seed,
            "generated_placement_rows": placementRows.count,
            "judge_disagreements": judgeDisagreements,
        ]))
        try rows.joined(separator: "\n").appending("\n")
            .write(toFile: options.outPath, atomically: true, encoding: .utf8)
        print("wrote \(rows.count) rows to \(options.outPath)")
    }
}

extension SyntheticRGBDMain {
    /// The challenge suite. It draws from its own RNG stream, so adding it
    /// cannot move a single regression row, and it skips the registration
    /// sweep: every scenario judges a single-part step under a locked pose.
    static func runChallenge(
        plan: InstructionPlan,
        engine: LDrawGeometryEngine,
        renderer: ExpectedDepthRenderer,
        fixtureStem: String,
        options: Options
    ) async throws {
        var rng = SplitMix64(seed: options.seed ^ 0xC4A1_1E46_E5E7)
        var rows: [String] = []
        var stepsUsed = 0
        var notApplicable: [String: Int] = [:]
        var dropped: [String: Int] = [:]
        // The placement index's symmetry (Chamfer, M2.0) is checked against
        // the render-based depth-equivalence oracle on every rotation row.
        var symmetryChecked = 0
        var symmetryDisagreements = 0
        let sourceRoot = URL(fileURLWithPath: options.modelPath).deletingLastPathComponent()
        let partPackRoot = URL(fileURLWithPath: options.ldrawRoot)
        let geometry = try await PlacementGeometryStore.shared.geometry(
            for: plan, sourceRoot: sourceRoot, partPackRoot: partPackRoot
        )
        var placementRows: [String] = []
        var judgeDisagreements = 0

        for step in plan.steps {
            let added = Array(plan.addedPlacements(for: step))
            // One part per step is what makes an edit unambiguous; the base
            // step (and any multi-part step) is outside the suite.
            guard added.count == 1, let placement = added.first else { continue }
            stepsUsed += 1
            let completed = try await engine.snapshot(placements: Array(plan.completedPlacements(before: step)))
            let delta = try await engine.snapshot(placements: added)
            let full = try await engine.snapshot(placements: Array(plan.cumulativePlacements(through: step)))
            // ≈ 33 cm from the eye: a handheld view of one part.
            let scene = SyntheticScene(renderer: renderer, model: full, minimumExtent: 0.2)

            for scenario in ChallengeScenario.all {
                let physicalDelta: InstructionGeometrySnapshot
                switch scenario.edit {
                case .buffers(let offset):
                    physicalDelta = InstructionGeometrySnapshot(
                        buffers: delta.buffers.map { $0.translated(by: offset) }, bounds: nil
                    )
                case .placement(let edit):
                    guard let edited = edit(placement) else {
                        notApplicable[scenario.label, default: 0] += 1
                        continue
                    }
                    physicalDelta = try await engine.snapshot(placements: [edited])
                }
                let challengeClass: String
                let expected: String
                var symmetricTurn = false
                switch scenario.expectation {
                case .verdict(let verdict):
                    (challengeClass, expected) = (scenario.label, verdict)
                case .completeIfDepthEquivalent:
                    let symmetric = try scene.depthEquivalent(delta, physicalDelta)
                    symmetricTurn = symmetric
                    challengeClass = scenario.label + (symmetric ? "_symmetric" : "_asymmetric")
                    expected = symmetric ? "complete" : "misplaced"
                    if let turns = scenario.quarterTurns {
                        let indexed = try await PlacementGeometryStore.shared.symmetry(
                            of: placement.partReference, in: plan, sourceRoot: sourceRoot, partPackRoot: partPackRoot
                        ).isSymmetric(quarterTurns: turns)
                        symmetryChecked += 1
                        if indexed != symmetric {
                            symmetryDisagreements += 1
                            print("symmetry disagreement: \(placement.partReference) \(scenario.label) index=\(indexed) oracle=\(symmetric)")
                        }
                    }
                }

                let started = ContinuousClock.now
                let (verdict, shadow) = try await scene.verify(
                    completed: completed,
                    delta: delta,
                    physical: InstructionGeometrySnapshot(buffers: completed.buffers + physicalDelta.buffers, bounds: nil),
                    sensor: SensorModel(rng: &rng),
                    shadow: (try BuildDiffEngine(renderer: renderer), StepGeometry(step: step, geometry: geometry))
                )
                let verifierMilliseconds = started.duration(to: .now).milliseconds - (shadow?.milliseconds ?? 0)
                if let shadow {
                    if !Row.sameAssessment(shadow.verdict, verdict) { judgeDisagreements += 1 }
                    if let diff = shadow.diff {
                        let truth = scenario.expectedPlacement(symmetricTurn: symmetricTurn)
                        placementRows += try Row.placements(
                            fixture: "\(fixtureStem)-s\(step.index)-\(scenario.label)-\(placement.partReference)",
                            diff: diff,
                            plan: plan,
                            expected: { _ in (truth.state, truth.offset) },
                            detectability: verdict.detectability,
                            observeOnly: truth.observeOnly,
                            expectedFailure: scenario.expectedFailure,
                            challengeClass: challengeClass,
                            latencyMilliseconds: shadow.milliseconds
                        )
                    }
                }
                // Same rule as the regression suite: an expected-complete
                // row below strong detectability is not a fair recall target.
                if expected == "complete", verdict.detectability != .strong {
                    dropped[challengeClass, default: 0] += 1
                    continue
                }
                rows.append(try Row.challenge(
                    fixture: "\(fixtureStem)-s\(step.index)-\(scenario.label)-\(placement.partReference)",
                    challengeClass: challengeClass,
                    expected: expected,
                    expectedFailure: scenario.expectedFailure,
                    verification: verdict,
                    latencyMilliseconds: verifierMilliseconds
                ))
            }
        }

        guard !rows.isEmpty else {
            throw CLIError("no challenge rows were generated from \(options.modelPath): it needs single-part steps")
        }
        let generated = rows.count
        rows.append(try Row.encode([
            "kind": "synthetic_summary",
            "schema_version": 1,
            "suite": "challenge",
            "fixture": fixtureStem,
            "seed": options.seed,
            "steps_sampled": stepsUsed,
            "generated_challenge_rows": generated,
            "dropped_expected_complete_below_strong": dropped.values.reduce(0, +),
            "dropped_by_class": dropped,
            "not_applicable_by_class": notApplicable,
        ]))
        rows.append(try Row.encode([
            "kind": "synthetic_summary",
            "schema_version": 1,
            "suite": "symmetry",
            "fixture": fixtureStem,
            "seed": options.seed,
            "checked": symmetryChecked,
            "oracle_disagreements": symmetryDisagreements,
        ]))
        rows += placementRows
        rows.append(try Row.encode([
            "kind": "synthetic_summary",
            "schema_version": 1,
            "suite": "challenge_placement",
            "fixture": fixtureStem,
            "seed": options.seed,
            "generated_placement_rows": placementRows.count,
            "judge_disagreements": judgeDisagreements,
        ]))
        try rows.joined(separator: "\n").appending("\n")
            .write(toFile: options.outPath, atomically: true, encoding: .utf8)
        print("wrote \(generated) challenge rows to \(options.outPath)")
    }
}

struct CLIError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Deterministic RNG so the corpus regenerates identically for a given seed.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func gaussian() -> Float {
        // Box-Muller from two uniforms.
        let u1 = max(Float(next() >> 11) * (1.0 / 9007199254740992.0), 1e-9)
        let u2 = Float(next() >> 11) * (1.0 / 9007199254740992.0)
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
}
