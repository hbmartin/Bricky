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
}

struct RegistrationPerturbation {
    let label: String
    let x: Float
    let z: Float
    let yawDegrees: Float

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

    /// Physical scene = completed geometry plus the scenario's version of the
    /// delta (present, absent, or shifted).
    func physicalSnapshot(
        completed: InstructionGeometrySnapshot,
        delta: InstructionGeometrySnapshot
    ) -> InstructionGeometrySnapshot {
        InstructionGeometrySnapshot(buffers: transform(completed, delta), bounds: nil)
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

    var intrinsics: simd_float3x3 {
        var matrix = matrix_identity_float3x3
        matrix[0][0] = 210
        matrix[1][1] = 210
        matrix[2][0] = 128
        matrix[2][1] = 96
        return matrix
    }

    private var boundsCenter: SIMD3<Float> {
        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for buffer in model.buffers {
            for point in buffer.positions {
                minimum = simd_min(minimum, point)
                maximum = simd_max(maximum, point)
            }
        }
        return (minimum + maximum) / 2
    }

    private var viewDistance: Float {
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        for buffer in model.buffers {
            for point in buffer.positions {
                minimum = simd_min(minimum, point)
                maximum = simd_max(maximum, point)
            }
        }
        let radius = simd_length(maximum - minimum) / 2
        return max(0.35, radius * 3)
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

    private var tableBuffer: LDrawGeometryBuffer {
        let center = boundsCenter
        let extent = viewDistance
        let up = SIMD3<Float>(0, 1, 0)
        let a = SIMD3<Float>(center.x - extent, 0, center.z - extent)
        let b = SIMD3<Float>(center.x + extent, 0, center.z - extent)
        let c = SIMD3<Float>(center.x + extent, 0, center.z + extent)
        let d = SIMD3<Float>(center.x - extent, 0, center.z + extent)
        return LDrawGeometryBuffer(
            colorCode: 0,
            positions: [a, b, c, a, c, d],
            normals: Array(repeating: up, count: 6),
            indices: [0, 1, 2, 3, 4, 5]
        )
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
            let yaw = currentYaw + smoothing * (targetYaw - currentYaw)
            var blended = matrix_identity_float4x4
            blended.columns.0 = SIMD4(cos(yaw), 0, -sin(yaw), 0)
            blended.columns.2 = SIMD4(sin(yaw), 0, cos(yaw), 0)
            blended.columns.3 = SIMD4(translation, 1)
            pose = blended
        }
        let translation = SIMD3(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
        let yaw = atan2(-pose.columns.0.z, pose.columns.0.x) * 180 / Float.pi
        let duration = started.duration(to: .now)
        return RegistrationOutcome(
            converged: simd_length(translation) <= 0.003 && abs(yaw) <= 2,
            translationErrorMeters: simd_length(translation),
            yawErrorDegrees: abs(yaw),
            reportedAmbiguous: lastQuality.latticeMargin < 1.3,
            latencyMilliseconds: Int(duration.components.seconds) * 1_000
                + Int(duration.components.attoseconds / 1_000_000_000_000_000)
        )
    }

    func verify(
        completed: InstructionGeometrySnapshot,
        delta: InstructionGeometrySnapshot,
        physical: InstructionGeometrySnapshot,
        sensor: SensorModel
    ) async throws -> StepVerification {
        var sensor = sensor
        let verifier = try GeometricStepVerifier()
        await verifier.begin(stepID: "synthetic", completedSnapshot: completed, deltaSnapshot: delta)
        let registration = ModelRegistration(
            alignmentID: UUID(),
            worldFromModel: matrix_identity_float4x4,
            state: .locked,
            quality: RegistrationQuality(rmsResidual: 0.002, inlierFraction: 0.8, latticeMargin: 2.0),
            fittedStepIndex: 0,
            timestamp: 0
        )
        var last: StepVerification?
        let view = viewPoses[0]
        for index in 0..<10 {
            let frame = try frame(
                of: physical,
                worldFromCamera: view,
                sensor: &sensor,
                timestamp: Double(index) * 0.1
            )
            last = try await verifier.ingest(frame: frame, registration: registration)
        }
        guard let last else { throw CLIError("verifier produced no assessment") }
        return last
    }
}

enum Row {
    static func encode(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    static func registration(fixture: String, outcome: RegistrationOutcome) -> String {
        encode([
            "kind": "registration",
            "schema_version": 1,
            "fixture_id": fixture,
            "converged": outcome.converged,
            "translation_error_m": Double(outcome.translationErrorMeters),
            "yaw_error_degrees": Double(outcome.yawErrorDegrees),
            "ambiguity_expected": false,
            "reported_ambiguous": outcome.reportedAmbiguous,
            "latency_ms": outcome.latencyMilliseconds,
        ])
    }

    static func verification(fixture: String, expected: String, verification: StepVerification) -> String {
        let produced: String
        switch verification.verdict {
        case .complete: produced = "complete"
        case .incomplete: produced = "incomplete"
        case .misplaced: produced = "misplaced"
        case .uncertain: produced = "uncertain"
        }
        return encode([
            "kind": "verification",
            "schema_version": 1,
            "fixture_id": fixture,
            "expected_verdict": expected,
            "produced_verdict": produced,
            "detectability": verification.detectability.rawValue,
            "frames_used": verification.framesUsed,
            "latency_ms": 1_000,
        ])
    }
}
