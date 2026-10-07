import Foundation
import simd

/// The LiDAR degradation applied to ideal rendered depth. Constants are
/// RECONSTRUCTED (CONTEXT.md): they must be calibrated against real captures
/// of a known build before release-gate numbers are trusted.
struct SensorModel {
    private var rng: SplitMix64
    /// σ(z) = base + range · z²  (meters).
    var baseNoise: Float = 0.003
    var rangeNoise: Float = 0.008
    var quantization: Float = 0.001
    /// Neighboring depth differing by more than this marks a discontinuity;
    /// its pixels drop to zero confidence, approximating edge dropout.
    var discontinuity: Float = 0.020

    init(rng: inout SplitMix64) {
        self.rng = SplitMix64(seed: rng.next())
    }

    mutating func degrade(_ map: ExpectedDepthMap) -> (depth: [Float32], confidence: [UInt8]) {
        var depth = [Float32](repeating: 0, count: map.depth.count)
        var confidence = [UInt8](repeating: 0, count: map.depth.count)
        for index in map.depth.indices {
            let ideal = map.depth[index]
            guard ideal > 0 else { continue }
            let sigma = baseNoise + rangeNoise * ideal * ideal
            var noisy = ideal + sigma * rng.gaussian()
            noisy = (noisy / quantization).rounded() * quantization
            depth[index] = max(0.001, noisy)
            confidence[index] = 2
        }
        // Discontinuity dropout, judged on the ideal map so noise cannot
        // mask a real edge.
        for y in 0..<map.height {
            for x in 0..<map.width {
                let index = y * map.width + x
                let center = map.depth[index]
                guard center > 0 else { continue }
                for (nx, ny) in [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)] {
                    guard nx >= 0, nx < map.width, ny >= 0, ny < map.height else { continue }
                    let neighbor = map.depth[ny * map.width + nx]
                    if neighbor <= 0 || abs(neighbor - center) > discontinuity {
                        confidence[index] = 0
                        break
                    }
                }
            }
        }
        return (depth, confidence)
    }

    /// ARKit's `smoothedSceneDepth` — the tracker's input — is spatially and
    /// temporally filtered; feeding the tracker raw noise makes observed
    /// normals near-random and breaks correspondence in a way the real
    /// pipeline never sees. Edge-aware 3×3 averaging models the smoothed
    /// stream honestly (real smoothing also lags fresh geometry, which is
    /// why the verifier gets the raw field instead).
    static func smooth(_ depth: [Float32], width: Int, height: Int, edge: Float = 0.015) -> [Float32] {
        var smoothed = depth
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                let center = depth[index]
                guard center > 0 else { continue }
                var sum: Float = 0
                var count: Float = 0
                for dy in -1...1 {
                    for dx in -1...1 {
                        let nx = x + dx
                        let ny = y + dy
                        guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                        let neighbor = depth[ny * width + nx]
                        guard neighbor > 0, abs(neighbor - center) <= edge else { continue }
                        sum += neighbor
                        count += 1
                    }
                }
                smoothed[index] = sum / count
            }
        }
        return smoothed
    }
}

struct RegistrationOutcome {
    let converged: Bool
    let translationErrorMeters: Float
    let yawErrorDegrees: Float
    let reportedAmbiguous: Bool
    let latencyMilliseconds: Int
    /// Signed error along world x and z (the truth is the origin, so these
    /// are the final translation): what tells a one-pitch slip from noise.
    var translationErrorX: Float = 0
    var translationErrorZ: Float = 0
    /// The last frame's lattice margin and the alternative that set it.
    var latticeMargin: Float = 0
    var latticeRunnerUp: LatticeAlternative? = nil
}

extension Duration {
    /// Whole milliseconds, for benchmark latency fields.
    var milliseconds: Int {
        Int(components.seconds) * 1_000 + Int(components.attoseconds / 1_000_000_000_000_000)
    }
}

struct RegistrationPerturbation {
    let label: String
    let x: Float
    let z: Float
    let yawDegrees: Float
    /// Whether this fixture is authored to be genuinely ambiguous (a
    /// symmetric or lattice-aliased basin the solver cannot uniquely
    /// resolve); the scorer judges such rows on reporting ambiguity, not on
    /// convergence. Every current sweep entry is a sub-lattice perturbation
    /// expected to converge to the unique truth.
    var ambiguityExpected = false

    var pose: simd_float4x4 {
        let yaw = yawDegrees * .pi / 180
        var matrix = matrix_identity_float4x4
        matrix.columns.0 = SIMD4(cos(yaw), 0, -sin(yaw), 0)
        matrix.columns.2 = SIMD4(sin(yaw), 0, cos(yaw), 0)
        matrix.columns.3 = SIMD4(x, 0, z, 1)
        return matrix
    }

    static let sweep: [RegistrationPerturbation] = [
        .init(label: "p5mm", x: 0.005, z: -0.003, yawDegrees: 0),
        .init(label: "p10mm", x: -0.010, z: 0.006, yawDegrees: 0),
        .init(label: "p20mm", x: 0.014, z: -0.014, yawDegrees: 0),
        .init(label: "y5deg", x: 0.004, z: 0.004, yawDegrees: 5),
        .init(label: "y10deg", x: -0.006, z: 0.004, yawDegrees: -10),
    ]
}

struct VerificationScenario {
    let label: String
    let expectedVerdict: String
    let transform: (InstructionGeometrySnapshot, InstructionGeometrySnapshot) -> [LDrawGeometryBuffer]
    /// The occluded scenario hides the delta behind completed geometry
    /// relative to the verifier's view pose, so detectability collapses to
    /// "undetectable" and the verifier must abstain.
    var occludesDelta = false

    /// What each delta placement truly is in this scenario, for the build
    /// diff's placement rows.
    var expectedPlacement: (state: String, offset: LatticeOffset?) {
        switch label {
        case "none": ("present", nil)
        case "missing": ("absent", nil)
        case "shift1x": ("displaced", LatticeOffset(dx: 1))
        default: ("not_observable", nil)
        }
    }

    /// Physical scene = completed geometry plus the scenario's version of the
    /// delta (present, absent, or shifted).
    func physicalSnapshot(
        completed: InstructionGeometrySnapshot,
        delta: InstructionGeometrySnapshot
    ) -> InstructionGeometrySnapshot {
        InstructionGeometrySnapshot(buffers: transform(completed, delta), bounds: nil)
    }

    /// Completed geometry as the verifier receives it. The occluded scenario
    /// folds the delta's surfaces into the completed snapshot, so from the
    /// verifier's view pose every delta pixel sits at or behind a completed
    /// surface: no visible footprint, detectability "undetectable",
    /// exercising the scorer's abstention floor.
    func authoredCompleted(
        completed: InstructionGeometrySnapshot,
        delta: InstructionGeometrySnapshot
    ) -> InstructionGeometrySnapshot {
        guard occludesDelta else { return completed }
        return InstructionGeometrySnapshot(buffers: completed.buffers + delta.buffers, bounds: nil)
    }

    static let taxonomy: [VerificationScenario] = [
        .init(label: "none", expectedVerdict: "complete") { completed, delta in
            completed.buffers + delta.buffers
        },
        .init(label: "missing", expectedVerdict: "incomplete") { completed, _ in
            completed.buffers
        },
        .init(label: "shift1x", expectedVerdict: "misplaced") { completed, delta in
            completed.buffers + delta.buffers.map { $0.translated(by: SIMD3(0.008, 0, 0)) }
        },
        // Delta fully hidden behind completed geometry from the verifier's
        // view: the brick is physically present but unverifiable, so the
        // verifier must abstain rather than guess.
        .init(label: "occluded", expectedVerdict: "uncertain", transform: { completed, delta in
            completed.buffers + delta.buffers
        }, occludesDelta: true),
    ]
}

extension LDrawGeometryBuffer {
    func translated(by offset: SIMD3<Float>) -> LDrawGeometryBuffer {
        LDrawGeometryBuffer(
            colorCode: colorCode,
            positions: positions.map { $0 + offset },
            normals: normals,
            indices: indices
        )
    }
}

/// One model's synthetic environment: derived camera views, tabletop, and
/// the render → degrade → solve/verify loops.
struct SyntheticScene {
    let renderer: ExpectedDepthRenderer
    let model: InstructionGeometrySnapshot
    let width = 256
    let height = 192
    /// Model bounds are scanned once here; every derived view quantity reads
    /// the cached values instead of rescanning the buffers.
    private let boundsCenter: SIMD3<Float>
    private let viewDistance: Float
    private let tableBuffer: LDrawGeometryBuffer

    /// `minimumExtent` floors the camera framing (the eye sits about 1.66×
    /// this from the model). The regression corpus keeps 0.35 m (≈ 58 cm);
    /// the challenge suite frames single parts at a handheld distance, since
    /// one part at 58 cm covers too few depth pixels to be judged at all.
    init(renderer: ExpectedDepthRenderer, model: InstructionGeometrySnapshot, minimumExtent: Float = 0.35) {
        self.renderer = renderer
        self.model = model
        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for buffer in model.buffers {
            for point in buffer.positions {
                minimum = simd_min(minimum, point)
                maximum = simd_max(maximum, point)
            }
        }
        let center = (minimum + maximum) / 2
        let extent = max(minimumExtent, simd_length(maximum - minimum) / 2 * 3)
        boundsCenter = center
        viewDistance = extent
        let up = SIMD3<Float>(0, 1, 0)
        let a = SIMD3<Float>(center.x - extent, 0, center.z - extent)
        let b = SIMD3<Float>(center.x + extent, 0, center.z - extent)
        let c = SIMD3<Float>(center.x + extent, 0, center.z + extent)
        let d = SIMD3<Float>(center.x - extent, 0, center.z + extent)
        tableBuffer = LDrawGeometryBuffer(
            colorCode: 0,
            positions: [a, b, c, a, c, d],
            normals: Array(repeating: up, count: 6),
            indices: [0, 1, 2, 3, 4, 5]
        )
    }

    var intrinsics: simd_float3x3 {
        var matrix = matrix_identity_float3x3
        matrix[0][0] = 210
        matrix[1][1] = 210
        matrix[2][0] = 128
        matrix[2][1] = 96
        return matrix
    }

    private func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>) -> simd_float4x4 {
        let forward = normalize(target - eye)
        let zAxis = -forward
        let xAxis = normalize(cross(SIMD3(0, 1, 0), zAxis))
        let yAxis = cross(zAxis, xAxis)
        var matrix = matrix_identity_float4x4
        matrix.columns.0 = SIMD4(xAxis, 0)
        matrix.columns.1 = SIMD4(yAxis, 0)
        matrix.columns.2 = SIMD4(zAxis, 0)
        matrix.columns.3 = SIMD4(eye, 1)
        return matrix
    }

    /// Two oblique views on opposite sides, the product's actual geometry:
    /// the user moves, and each view constrains the directions it can see.
    /// An oblique view from `azimuthDegrees` around the build (0 = from +z,
    /// 90 = from +x), at the regression views' elevation and distance.
    func obliquePose(azimuthDegrees: Float) -> simd_float4x4 {
        let radians = azimuthDegrees * .pi / 180
        let reach = viewDistance * 1.35
        return lookAt(
            eye: SIMD3(boundsCenter.x + reach * sin(radians), viewDistance * 0.85, boundsCenter.z + reach * cos(radians)),
            target: boundsCenter
        )
    }

    /// Nearly straight down onto the build.
    var overheadPose: simd_float4x4 {
        lookAt(
            eye: SIMD3(boundsCenter.x, boundsCenter.y + viewDistance, boundsCenter.z + viewDistance * 0.01),
            target: boundsCenter
        )
    }

    var viewPoses: [simd_float4x4] {
        let center = boundsCenter
        let distance = viewDistance
        let elevation = distance * 0.85
        return [
            lookAt(
                eye: SIMD3(center.x + distance, elevation, center.z + distance),
                target: center
            ),
            lookAt(
                eye: SIMD3(center.x - distance, elevation, center.z + distance * 0.9),
                target: center
            ),
        ]
    }

    /// Whether two snapshots are indistinguishable to depth: ideal renders
    /// from both verification views and from overhead differ nowhere by more
    /// than `tolerance`. The oracle for "symmetric" in the challenge suite —
    /// a rotated part that renders identically is a correct build as far as
    /// any depth verifier can know.
    func depthEquivalent(
        _ lhs: InstructionGeometrySnapshot,
        _ rhs: InstructionGeometrySnapshot,
        tolerance: Float = 0.0005
    ) throws -> Bool {
        for pose in viewPoses + [overheadPose] {
            let maps = try [lhs, rhs].map { snapshot in
                try renderer.render(
                    snapshot: snapshot,
                    viewFromModel: pose.inverse,
                    intrinsics: intrinsics,
                    width: width,
                    height: height
                )
            }
            for index in maps[0].depth.indices {
                let (a, b) = (maps[0].depth[index], maps[1].depth[index])
                if (a > 0) != (b > 0) || abs(a - b) > tolerance {
                    return false
                }
            }
        }
        return true
    }

    func frame(
        of physical: InstructionGeometrySnapshot,
        worldFromCamera: simd_float4x4,
        sensor: inout SensorModel,
        timestamp: TimeInterval
    ) throws -> RegistrationFrameInput {
        let scene = InstructionGeometrySnapshot(
            buffers: physical.buffers + [tableBuffer],
            bounds: nil
        )
        let ideal = try renderer.render(
            snapshot: scene,
            viewFromModel: worldFromCamera.inverse,
            intrinsics: intrinsics,
            width: width,
            height: height
        )
        let (raw, confidence) = sensor.degrade(ideal)
        let smoothed = SensorModel.smooth(raw, width: width, height: height)
        return RegistrationFrameInput(
            depth: smoothed,
            confidence: confidence,
            rawDepth: raw,
            rawConfidence: confidence,
            width: width,
            height: height,
            depthIntrinsics: intrinsics,
            worldFromCamera: worldFromCamera,
            timestamp: timestamp
        )
    }

    func solveRegistration(
        perturbation: RegistrationPerturbation,
        sensor: SensorModel
    ) throws -> RegistrationOutcome {
        var sensor = sensor
        let started = ContinuousClock.now
        let sample = ModelSurfaceSampler.sample(model, stepIndex: 0)
        var pose = perturbation.pose
        var lastQuality = RegistrationQuality.none
        // The app's tracker converges by consuming a ~10 Hz stream with
        // exponential pose smoothing, which is what averages sensor noise
        // down to millimetres; a single-frame solve cannot. Mimic it:
        // alternating views with fresh noise per frame, blended like
        // DepthICPTracker's ingest loop.
        let smoothing: Float = 0.3
        for frameIndex in 0..<12 {
            let view = viewPoses[frameIndex % viewPoses.count]
            let frame = try frame(of: model, worldFromCamera: view, sensor: &sensor, timestamp: Double(frameIndex) * 0.1)
            let result = DepthICPTracker.solve(sample: sample, frame: frame, initialWorldFromModel: pose)
            lastQuality = result.quality
            if frameIndex == 0, ProcessInfo.processInfo.environment["BRICKY_SYNTH_DEBUG"] != nil {
                let up = sample.normals.filter { $0.y > 0.7 }.count
                let down = sample.normals.filter { $0.y < -0.7 }.count
                let yValues = sample.points.map(\.y)
                let upHigh = zip(sample.points, sample.normals)
                    .filter { $0.1.y > 0.7 }
                    .map(\.0.y)
                FileHandle.standardError.write(Data(
                    "DBG normals up=\(up) down=\(down) total=\(sample.normals.count) yRange=(\(yValues.min() ?? 0),\(yValues.max() ?? 0)) upNormalMeanY=\(upHigh.isEmpty ? -1 : upHigh.reduce(0,+) / Float(upHigh.count))\n".utf8
                ))
            }
            if ProcessInfo.processInfo.environment["BRICKY_SYNTH_DEBUG"] != nil {
                let t = result.worldFromModel.columns.3
                FileHandle.standardError.write(Data(
                    "DBG \(perturbation.label) f\(frameIndex) inl=\(result.quality.inlierFraction) rms=\(result.quality.rmsResidual) margin=\(result.quality.latticeMargin) t=(\(t.x),\(t.y),\(t.z))\n".utf8
                ))
            }
            guard result.quality.inlierFraction > 0.3 else { continue }
            let current = SIMD3(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
            let target = SIMD3(
                result.worldFromModel.columns.3.x,
                result.worldFromModel.columns.3.y,
                result.worldFromModel.columns.3.z
            )
            let currentYaw = atan2(-pose.columns.0.z, pose.columns.0.x)
            let targetYaw = atan2(-result.worldFromModel.columns.0.z, result.worldFromModel.columns.0.x)
            let translation = simd_mix(current, target, SIMD3(repeating: smoothing))
            // Shortest-arc yaw delta: normalize to [-π, π] so smoothing
            // across the ±π branch cut does not swing the long way around.
            var yawDelta = (targetYaw - currentYaw).truncatingRemainder(dividingBy: 2 * .pi)
            if yawDelta > .pi { yawDelta -= 2 * .pi }
            if yawDelta < -.pi { yawDelta += 2 * .pi }
            let yaw = currentYaw + smoothing * yawDelta
            var blended = matrix_identity_float4x4
            blended.columns.0 = SIMD4(cos(yaw), 0, -sin(yaw), 0)
            blended.columns.2 = SIMD4(sin(yaw), 0, cos(yaw), 0)
            blended.columns.3 = SIMD4(translation, 1)
            pose = blended
        }
        let translation = SIMD3(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
        let yaw = atan2(-pose.columns.0.z, pose.columns.0.x) * 180 / Float.pi
        let duration = started.duration(to: .now)
        // Converged is the solver's own lock signal (DepthICPTracker's lock
        // thresholds on fit quality), independent of the accuracy numbers
        // the scorer gates on — a sloppy-but-locked fit must be able to
        // surface as converged-with-error.
        let lock = DepthICPTracker.Configuration()
        return RegistrationOutcome(
            converged: lastQuality.rmsResidual <= lock.lockRMS
                && lastQuality.inlierFraction >= lock.lockInlierFraction,
            translationErrorMeters: simd_length(translation),
            yawErrorDegrees: abs(yaw),
            reportedAmbiguous: lastQuality.latticeMargin < 1.3,
            latencyMilliseconds: duration.milliseconds,
            translationErrorX: translation.x,
            translationErrorZ: translation.z,
            latticeMargin: lastQuality.latticeMargin,
            latticeRunnerUp: lastQuality.latticeRunnerUp
        )
    }

    func verify(
        completed: InstructionGeometrySnapshot,
        delta: InstructionGeometrySnapshot,
        physical: InstructionGeometrySnapshot,
        sensor: SensorModel
    ) async throws -> StepVerification {
        try await verify(completed: completed, delta: delta, physical: physical, sensor: sensor, shadow: nil).verification
    }

    /// What a shadow judge concluded beside the verifier, on the same frames.
    struct ShadowResult {
        let verdict: StepVerification
        let diff: BuildDiff?
        let milliseconds: Int
    }

    /// `verify`, also feeding every frame to `shadow` (the build diff, M2.3)
    /// when given. The shadow draws no randomness and is timed apart, so the
    /// verifier's rows are unchanged by it.
    func verify(
        completed: InstructionGeometrySnapshot,
        delta: InstructionGeometrySnapshot,
        physical: InstructionGeometrySnapshot,
        sensor: SensorModel,
        shadow: (judge: BuildDiffEngine, geometry: StepGeometry)?,
        view: simd_float4x4? = nil
    ) async throws -> (verification: StepVerification, shadow: ShadowResult?) {
        var sensor = sensor
        let verifier = try GeometricStepVerifier(renderer: renderer)
        await verifier.begin(stepID: "synthetic", completedSnapshot: completed, deltaSnapshot: delta)
        if let shadow { await shadow.judge.begin(stepID: "synthetic", geometry: shadow.geometry) }
        var shadowVerdict: StepVerification?
        var shadowDuration = Duration.zero
        let registration = ModelRegistration(
            alignmentID: UUID(),
            worldFromModel: matrix_identity_float4x4,
            state: .locked,
            quality: RegistrationQuality(rmsResidual: 0.002, inlierFraction: 0.8, latticeMargin: 2.0),
            fittedStepIndex: 0,
            timestamp: 0
        )
        var last: StepVerification?
        let view = view ?? viewPoses[0]
        for index in 0..<10 {
            let frame = try frame(
                of: physical,
                worldFromCamera: view,
                sensor: &sensor,
                timestamp: Double(index) * 0.1
            )
            last = try await verifier.ingest(frame: frame, registration: registration)
            if let shadow {
                let started = ContinuousClock.now
                shadowVerdict = try await shadow.judge.ingest(frame: frame, registration: registration)
                shadowDuration += started.duration(to: .now)
            }
        }
        guard let last else { throw CLIError("verifier produced no assessment") }
        guard let shadow, let shadowVerdict else { return (last, nil) }
        return (last, ShadowResult(
            verdict: shadowVerdict, diff: await shadow.judge.lastDiff, milliseconds: shadowDuration.milliseconds
        ))
    }
}

enum Row {
    static func encode(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func registration(
        fixture: String,
        ambiguityExpected: Bool,
        outcome: RegistrationOutcome
    ) throws -> String {
        var row: [String: Any] = [
            "kind": "registration",
            "provenance": "synthetic",
            "schema_version": 1,
            "fixture_id": fixture,
            "converged": outcome.converged,
            "translation_error_m": Double(outcome.translationErrorMeters),
            "translation_error_x_m": Double(outcome.translationErrorX),
            "translation_error_z_m": Double(outcome.translationErrorZ),
            "yaw_error_degrees": Double(outcome.yawErrorDegrees),
            "ambiguity_expected": ambiguityExpected,
            "reported_ambiguous": outcome.reportedAmbiguous,
            "latency_ms": outcome.latencyMilliseconds,
        ]
        // A margin above Float's range is "no alternative competed"; JSON
        // has no infinity, and the runner-up is absent in that case anyway.
        if outcome.latticeMargin.isFinite, outcome.latticeMargin < .greatestFiniteMagnitude {
            row["lattice_margin"] = Double(outcome.latticeMargin)
        }
        if let runnerUp = outcome.latticeRunnerUp {
            row["lattice_runner_up"] = runnerUp.rawValue
        }
        return try encode(row)
    }

    static func verification(
        fixture: String,
        expected: String,
        verification: StepVerification,
        latencyMilliseconds: Int
    ) throws -> String {
        let produced = producedVerdict(verification.verdict)
        var row: [String: Any] = [
            "kind": "verification",
            "provenance": "synthetic",
            "schema_version": 1,
            "fixture_id": fixture,
            "expected_verdict": expected,
            "produced_verdict": produced,
            "detectability": verification.detectability.rawValue,
            "frames_used": verification.framesUsed,
            "latency_ms": latencyMilliseconds,
        ]
        if let contests = verification.latticeContests { row["lattice_contests"] = latticeContests(contests) }
        return try encode(row)
    }

    /// Lattice contests in the evidence-window layout.
    static func latticeContests(_ contests: [LatticeContest]) -> [[String: Any]] {
        contests.map { contest in
            [
                "offset_studs": [contest.offsetStuds.x, contest.offsetStuds.y],
                "wins_complete": contest.winsComplete,
                "wins_shifted": contest.winsShifted,
            ]
        }
    }

    static func challenge(
        fixture: String,
        challengeClass: String,
        expected: String,
        expectedFailure: Bool,
        verification: StepVerification,
        latencyMilliseconds: Int
    ) throws -> String {
        var row: [String: Any] = [
            "kind": "verification_challenge",
            "provenance": "synthetic",
            "schema_version": 1,
            "fixture_id": fixture,
            "challenge_class": challengeClass,
            "expected_verdict": expected,
            "expected_failure": expectedFailure,
            "produced_verdict": producedVerdict(verification.verdict),
            "detectability": verification.detectability.rawValue,
            "frames_used": verification.framesUsed,
            "latency_ms": latencyMilliseconds,
        ]
        if let contests = verification.latticeContests { row["lattice_contests"] = latticeContests(contests) }
        return try encode(row)
    }

    /// One `placement` row per observed placement of a shadow diff.
    static func placements(
        fixture: String,
        diff: BuildDiff,
        plan: InstructionPlan,
        expected: (Int) -> (state: String, offset: LatticeOffset?),
        detectability: DeltaDetectability,
        observeOnly: Bool = false,
        expectedFailure: Bool = false,
        challengeClass: String? = nil,
        latencyMilliseconds: Int
    ) throws -> [String] {
        try diff.observations.map { observation in
            let truth = expected(observation.placement)
            var row: [String: Any] = [
                "kind": "placement",
                "provenance": "synthetic",
                "schema_version": 1,
                "fixture_id": "\(fixture)-p\(observation.placement)",
                "placement_id": plan.placementTimeline.indices.contains(observation.placement)
                    ? plan.placementTimeline[observation.placement].id : "\(observation.placement)",
                "expected_state": truth.state,
                "produced_state": observation.state.name,
                "observe_only": observeOnly,
                "expected_failure": expectedFailure,
                "detectability": detectability.rawValue,
                "support": observation.evidence.support,
                "absence": observation.evidence.absence,
                "unexplained": observation.evidence.unexplained,
                "latency_ms": latencyMilliseconds,
            ]
            if let offset = truth.offset { row["expected_offset"] = [offset.dx, offset.dz, offset.dy, offset.quarterTurns] }
            switch observation.state {
            case .displaced(let offset): row["produced_offset"] = [offset.dx, offset.dz, offset.dy, offset.quarterTurns]
            case .rotated(let turns): row["produced_offset"] = [0, 0, 0, turns]
            default: break
            }
            if let challengeClass { row["challenge_class"] = challengeClass }
            if !observation.evidence.tallies.isEmpty {
                row["tallies"] = observation.evidence.tallies.map { tally in
                    [
                        "offset": [tally.offset.dx, tally.offset.dz, tally.offset.dy, tally.offset.quarterTurns],
                        "wins_present": tally.winsPresent,
                        "wins_alternative": tally.winsAlternative,
                    ]
                }
            }
            return try encode(row)
        }
    }

    /// True when two assessments agree in every field the verifier reports.
    static func sameAssessment(_ lhs: StepVerification, _ rhs: StepVerification) -> Bool {
        lhs.verdict == rhs.verdict && lhs.detectability == rhs.detectability
            && lhs.deltaPixels == rhs.deltaPixels && lhs.framesUsed == rhs.framesUsed
            && lhs.completeFraction.bitPattern == rhs.completeFraction.bitPattern
            && lhs.incompleteFraction.bitPattern == rhs.incompleteFraction.bitPattern
    }

    static func producedVerdict(_ verdict: StepVerdict) -> String {
        switch verdict {
        case .complete: "complete"
        case .incomplete: "incomplete"
        case .misplaced: "misplaced"
        case .uncertain: "uncertain"
        }
    }
}
