import Foundation
import simd

/// What noise-free renders say about one scene's lattice alternatives: the
/// truth the lattice suite judges registration against, decided without
/// the tracker. An alternative is depth-identical when it renders within
/// 0.5 mm of the authored pose at every pixel from every view; "near" when
/// under 2% of the covered pixels differ, which is where aliasing on real
/// LiDAR would be expected to start.
struct LatticeOracle {
    enum Verdict: String {
        case exact
        case near
        case none
    }

    static let nearFraction: Float = 0.02

    /// Alternatives that render depth-identically to the authored pose.
    let exact: [LatticeAlternative]
    /// Alternatives with differing pixels under `nearFraction`.
    let near: [LatticeAlternative]

    /// Ambiguity is expected only where depth genuinely cannot decide.
    var expected: Bool { !exact.isEmpty }
    var verdict: Verdict { !exact.isEmpty ? .exact : (!near.isEmpty ? .near : .none) }

    var rowFields: [String: Any] {
        [
            "ambiguity_oracle": verdict.rawValue,
            "ambiguity_alternatives": exact.map(\.rawValue),
            "near_alternatives": near.map(\.rawValue),
        ]
    }

    /// Judges the tracker's own alternatives — the same poses, about the
    /// same centroid — for `model` at the identity pose.
    static func judge(scene: SyntheticScene, model: InstructionGeometrySnapshot) throws -> LatticeOracle {
        let sample = ModelSurfaceSampler.sample(model, stepIndex: 0)
        let alternatives = DepthICPTracker.latticeAlternatives(
            sample: sample, pose: matrix_identity_float4x4, configuration: DepthICPTracker.Configuration()
        )
        var exact: [LatticeAlternative] = []
        var near: [LatticeAlternative] = []
        for (kind, pose) in alternatives {
            let moved = InstructionGeometrySnapshot(buffers: model.buffers.map { $0.transformed(by: pose) }, bounds: nil)
            let fraction = try scene.depthDifferenceFraction(model, moved)
            if fraction == 0 {
                exact.append(kind)
            } else if fraction < nearFraction {
                near.append(kind)
            }
        }
        return LatticeOracle(exact: exact, near: near)
    }
}

extension LDrawGeometryBuffer {
    /// The buffer under a rigid transform: positions moved, normals turned.
    func transformed(by transform: simd_float4x4) -> LDrawGeometryBuffer {
        let rotation = simd_float3x3(
            SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
            SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
            SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        )
        return LDrawGeometryBuffer(
            colorCode: colorCode,
            positions: positions.map { point in
                let moved = transform * SIMD4(point, 1)
                return SIMD3(moved.x, moved.y, moved.z)
            },
            normals: normals.map { rotation * $0 },
            indices: indices
        )
    }
}

extension SyntheticRGBDMain {
    /// The regression sweep plus two starts a whole stud pitch off, which
    /// is where a lattice alias would hold the solve.
    static let latticePerturbations: [RegistrationPerturbation] = RegistrationPerturbation.sweep + [
        .init(label: "p1pitchx", x: 0.008, z: 0, yawDegrees: 0),
        .init(label: "p1pitchz", x: 0, z: 0.008, yawDegrees: 0),
    ]

    /// The lattice suite (Phase 4): does registration report stud-lattice
    /// aliasing where depth genuinely cannot tell the poses apart, and does
    /// it ever settle a whole pitch off where depth can? Each step's
    /// addition is one scene on its own, framed at a handheld distance. It
    /// draws from its own RNG stream, so no regression row moves.
    static func runLattice(
        plan: InstructionPlan,
        renderer: ExpectedDepthRenderer,
        fixtureStem: String,
        options: Options
    ) async throws {
        var rng = SplitMix64(seed: options.seed ^ 0x1A77_1CE5_0F57)
        let geometry = try await PlacementGeometryStore.shared.geometry(
            for: plan,
            sourceRoot: URL(fileURLWithPath: options.modelPath).deletingLastPathComponent(),
            partPackRoot: URL(fileURLWithPath: options.ldrawRoot)
        )
        var rows: [String] = []
        var scenes = 0
        var ambiguousScenes = 0
        var nearScenes = 0
        for step in plan.steps {
            let delta = geometry.deltaSnapshot(for: step)
            guard !delta.buffers.isEmpty else { continue }
            scenes += 1
            // ≈ 33 cm from the eye, as the challenge suite frames one part.
            let scene = SyntheticScene(renderer: renderer, model: delta, minimumExtent: 0.2)
            let oracle = try LatticeOracle.judge(scene: scene, model: delta)
            switch oracle.verdict {
            case .exact: ambiguousScenes += 1
            case .near: nearScenes += 1
            case .none: break
            }
            for perturbation in latticePerturbations {
                let outcome = try scene.solveRegistration(perturbation: perturbation, sensor: SensorModel(rng: &rng))
                rows.append(try Row.registration(
                    fixture: "\(fixtureStem)-s\(step.index)-\(perturbation.label)",
                    ambiguityExpected: oracle.expected,
                    outcome: outcome,
                    extra: oracle.rowFields
                ))
            }
        }
        guard !rows.isEmpty else {
            throw CLIError("no lattice rows were generated from \(options.modelPath)")
        }
        let registrationRows = rows.count
        rows.append(try Row.encode([
            "kind": "synthetic_summary",
            "schema_version": 1,
            "suite": "lattice",
            "fixture": fixtureStem,
            "seed": options.seed,
            "scenes": scenes,
            "ambiguous_scenes": ambiguousScenes,
            "near_scenes": nearScenes,
            "generated_registration_rows": registrationRows,
        ]))
        try rows.joined(separator: "\n").appending("\n")
            .write(toFile: options.outPath, atomically: true, encoding: .utf8)
        print("wrote \(rows.count) rows to \(options.outPath): \(scenes) scenes, \(ambiguousScenes) ambiguous, \(nearScenes) near")
    }
}
