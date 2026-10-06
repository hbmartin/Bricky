import Foundation
import simd

/// The suggested-placement suite (M2.7): for sampled steps, the build is
/// rendered on the table and the suggestion is asked for from three aims:
/// - on the build: a proposal must land on the true pose, within a stud and
///   20° (or a half turn, for builds that look the same turned round);
/// - beside it on the bare table, and on a distractor box: there is nothing
///   of the build there, so any proposal off the true pose is wrong.
/// Declining to propose is never wrong; proposing wrongly is what the 5%
/// gate counts.
extension SyntheticRGBDMain {
    static func runPlacementSuggestion(
        plan: InstructionPlan, renderer: ExpectedDepthRenderer, fixtureStem: String, options: Options
    ) async throws {
        var rng = SplitMix64(seed: options.seed ^ 0x9A1C_E5D0)
        let geometry = try await PlacementGeometryStore.shared.geometry(
            for: plan,
            sourceRoot: URL(fileURLWithPath: options.modelPath).deletingLastPathComponent(),
            partPackRoot: URL(fileURLWithPath: options.ldrawRoot)
        )
        let candidates = plan.steps.indices.filter { plan.steps[$0].cumulativePlacementCount > 0 }
        let sampled = RecoveryIndexing.evenlySampledIndices(
            count: min(options.sampledSteps, candidates.count), range: 0..<candidates.count
        ).map { candidates[$0] }
        var rows: [String] = []
        var proposals = 0
        var wrong = 0
        for stepIndex in sampled {
            let step = plan.steps[stepIndex]
            let build = geometry.cumulativeSnapshot(through: step)
            let scene = SyntheticScene(renderer: renderer, model: build, minimumExtent: 0.2)
            let view = scene.viewPoses[0]
            let points = build.buffers.flatMap(\.positions)
            let centre = points.reduce(SIMD3<Float>.zero, +) / Float(max(1, points.count))
            // Whether the build looks the same turned round is asked only
            // when a proposal is a half turn off, with the challenge suite's
            // render-based oracle.
            var halfTurnSymmetric: Bool?
            func looksTheSameTurnedRound() throws -> Bool {
                if let halfTurnSymmetric { return halfTurnSymmetric }
                let turned = InstructionGeometrySnapshot(
                    buffers: build.buffers.map { buffer in
                        LDrawGeometryBuffer(
                            colorCode: buffer.colorCode,
                            positions: buffer.positions.map { SIMD3(-$0.x, $0.y, -$0.z) },
                            normals: buffer.normals.map { SIMD3(-$0.x, $0.y, -$0.z) },
                            indices: buffer.indices
                        )
                    },
                    bounds: nil
                )
                let answer = try scene.depthEquivalent(build, turned)
                halfTurnSymmetric = answer
                return answer
            }
            let maximumX = points.map(\.x).max() ?? 0
            let aside = SIMD3<Float>(maximumX + 0.06, 0.008, centre.z)
            let distractor = box(min: SIMD3(aside.x - 0.016, 0, aside.z - 0.008), max: SIMD3(aside.x + 0.016, 0.0192, aside.z + 0.008))
            let scenarios: [(String, InstructionGeometrySnapshot, SIMD3<Float>)] = [
                ("on_build", build, centre),
                ("off_build", build, SIMD3(aside.x, 0, aside.z)),
                ("distractor", InstructionGeometrySnapshot(buffers: build.buffers + [distractor], bounds: nil), aside),
            ]
            for (name, physical, aim) in scenarios {
                var sensor = SensorModel(rng: &rng)
                let frame = try scene.frame(of: physical, worldFromCamera: view, sensor: &sensor, timestamp: 0)
                guard let reticle = pixel(of: aim, view: view, intrinsics: scene.intrinsics, width: scene.width, height: scene.height) else { continue }
                let outcome = try await SuggestedPlacementEstimator.suggest(
                    frame: frame, reticle: reticle, planeHeight: 0, build: build, renderer: renderer
                )
                var row: [String: Any] = [
                    "kind": "placement_suggestion",
                    "schema_version": 1,
                    "provenance": "synthetic",
                    "fixture_id": "\(fixtureStem)-s\(step.index)-\(name)",
                    "scenario": name,
                ]
                switch outcome {
                case .proposal(let placement):
                    let translation = simd_distance(
                        SIMD3(placement.worldFromModel.columns.3.x, placement.worldFromModel.columns.3.y, placement.worldFromModel.columns.3.z),
                        .zero
                    )
                    let yaw = abs(SuggestedPlacementEstimator.yawDifferenceDegrees(placement.worldFromModel, matrix_identity_float4x4))
                    var yawOK = yaw <= 20
                    if !yawOK, abs(yaw - 180) <= 20 { yawOK = try looksTheSameTurnedRound() }
                    let correct = translation <= 0.008 && yawOK
                    proposals += 1
                    wrong += correct ? 0 : 1
                    row["outcome"] = correct ? "correct" : "wrong"
                    row["translation_error_m"] = translation
                    row["yaw_error_deg"] = yaw
                case .noProposal(let reason):
                    row["outcome"] = "none"
                    row["reason"] = switch reason {
                    case .nothingBuilt: "nothing_built"
                    case .noBlob: "no_blob"
                    case .poorFit: "poor_fit"
                    case .ambiguous: "ambiguous"
                    }
                }
                rows.append(try Row.encode(row))
            }
        }
        guard !rows.isEmpty else { throw CLIError("no placement rows were generated from \(options.modelPath)") }
        let generated = rows.count
        rows.append(try Row.encode([
            "kind": "synthetic_summary",
            "schema_version": 1,
            "suite": "placement_suggestion",
            "fixture": fixtureStem,
            "seed": options.seed,
            "generated_placement_suggestion_rows": generated,
            "proposals": proposals,
            "wrong_proposals": wrong,
        ]))
        try rows.joined(separator: "\n").appending("\n")
            .write(toFile: options.outPath, atomically: true, encoding: .utf8)
        print("wrote \(generated) placement rows to \(options.outPath) (\(proposals) proposals, \(wrong) wrong)")
    }

    static func pixel(of world: SIMD3<Float>, view: simd_float4x4, intrinsics: simd_float3x3, width: Int, height: Int) -> SIMD2<Int>? {
        let camera = view.inverse * SIMD4(world, 1)
        let depth = -camera.z
        guard depth > 0 else { return nil }
        let x = Int((intrinsics[0][0] * camera.x / depth + intrinsics[2][0]).rounded())
        let y = Int((-intrinsics[1][1] * camera.y / depth + intrinsics[2][1]).rounded())
        guard (0..<width).contains(x), (0..<height).contains(y) else { return nil }
        return SIMD2(x, y)
    }

    static func box(min lo: SIMD3<Float>, max hi: SIMD3<Float>) -> LDrawGeometryBuffer {
        var positions: [SIMD3<Float>] = []
        func face(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>) {
            positions.append(contentsOf: [a, b, c, a, c, d])
        }
        face(SIMD3(lo.x, hi.y, lo.z), SIMD3(hi.x, hi.y, lo.z), SIMD3(hi.x, hi.y, hi.z), SIMD3(lo.x, hi.y, hi.z))
        face(SIMD3(lo.x, lo.y, hi.z), SIMD3(lo.x, hi.y, hi.z), SIMD3(hi.x, hi.y, hi.z), SIMD3(hi.x, lo.y, hi.z))
        face(SIMD3(lo.x, lo.y, lo.z), SIMD3(hi.x, lo.y, lo.z), SIMD3(hi.x, hi.y, lo.z), SIMD3(lo.x, hi.y, lo.z))
        face(SIMD3(hi.x, lo.y, lo.z), SIMD3(hi.x, lo.y, hi.z), SIMD3(hi.x, hi.y, hi.z), SIMD3(hi.x, hi.y, lo.z))
        face(SIMD3(lo.x, lo.y, lo.z), SIMD3(lo.x, hi.y, lo.z), SIMD3(lo.x, hi.y, hi.z), SIMD3(lo.x, lo.y, hi.z))
        return LDrawGeometryBuffer(
            colorCode: 7, positions: positions, normals: Array(repeating: SIMD3(0, 1, 0), count: positions.count),
            indices: positions.indices.map(UInt32.init)
        )
    }
}
