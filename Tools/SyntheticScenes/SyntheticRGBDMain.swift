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

    struct Options {
        var modelPath: String
        var ldrawRoot: String
        var outPath: String
        var seed: UInt64 = 42
        var sampledSteps = 6
    }

    static func parseOptions() throws -> Options {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard let modelPath = arguments.first, !modelPath.hasPrefix("--") else {
            throw CLIError("usage: SyntheticRGBD <model.mpd|.ldr> --ldraw-root <dir> --out <results.ndjson> [--seed N] [--steps N]")
        }
        arguments.removeFirst()
        var options = Options(modelPath: modelPath, ldrawRoot: "", outPath: "")
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            guard index + 1 < arguments.count else { throw CLIError("missing value for \(flag)") }
            let value = arguments[index + 1]
            switch flag {
            case "--ldraw-root": options.ldrawRoot = value
            case "--out": options.outPath = value
            case "--seed": options.seed = UInt64(value) ?? 42
            case "--steps": options.sampledSteps = max(1, Int(value) ?? 6)
            default: throw CLIError("unknown flag \(flag)")
            }
            index += 2
        }
        guard !options.ldrawRoot.isEmpty, !options.outPath.isEmpty else {
            throw CLIError("--ldraw-root and --out are required")
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
        var rng = SplitMix64(seed: options.seed)
        var rows: [String] = []

        let stepIndices = HierarchicalIndices.evenly(
            count: min(options.sampledSteps, plan.steps.count),
            range: 0..<plan.steps.count
        )

        for stepIndex in stepIndices {
            let step = plan.steps[stepIndex]
            let completed = try await engine.snapshot(placements: Array(plan.completedPlacements(before: step)))
            let delta = try await engine.snapshot(placements: Array(plan.addedPlacements(for: step)))
            let full = try await engine.snapshot(placements: Array(plan.cumulativePlacements(through: step)))
            guard !full.buffers.isEmpty else { continue }

            let scene = SyntheticScene(renderer: renderer, model: full)

            // Registration sweep on the full build: perturbed inits, solved
            // over two viewpoints like the product's actual geometry.
            for perturbation in RegistrationPerturbation.sweep {
                let outcome = try scene.solveRegistration(
                    perturbation: perturbation,
                    sensor: SensorModel(rng: &rng)
                )
                rows.append(Row.registration(
                    fixture: "\(fixtureStem)-s\(stepIndex)-\(perturbation.label)",
                    outcome: outcome
                ))
            }

            // Verification scenarios: the physical scene carries the injected
            // error, the verifier judges the authored delta.
            for scenario in VerificationScenario.taxonomy {
                let physical = scenario.physicalSnapshot(completed: completed, delta: delta)
                let verdict = try await scene.verify(
                    completed: completed,
                    delta: delta,
                    physical: physical,
                    sensor: SensorModel(rng: &rng)
                )
                rows.append(Row.verification(
                    fixture: "\(fixtureStem)-s\(stepIndex)-\(scenario.label)",
                    expected: scenario.expectedVerdict,
                    verification: verdict
                ))
            }
        }

        try rows.joined(separator: "\n").appending("\n")
            .write(toFile: options.outPath, atomically: true, encoding: .utf8)
        print("wrote \(rows.count) rows to \(options.outPath)")
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

enum HierarchicalIndices {
    static func evenly(count: Int, range: Range<Int>) -> [Int] {
        guard count > 0, !range.isEmpty else { return [] }
        if count == 1 { return [range.lowerBound] }
        return (0..<count).map { offset in
            range.lowerBound + Int((Double(range.count - 1) * Double(offset) / Double(count - 1)).rounded())
        }
    }
}
