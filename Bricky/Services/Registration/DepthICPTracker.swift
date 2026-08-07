import Foundation
import simd

/// Fits the expected model surface to LiDAR depth: projective point-to-plane
/// ICP, gravity-constrained to 4 DoF (translation + yaw) because the build
/// sits on a plane in ARKit's gravity-aligned world (ADR 0009). The solver
/// is a pure function over one frame so it is testable against synthetic
/// depth; the actor adds the state machine, smoothing, and stream plumbing.
actor DepthICPTracker {
    struct Configuration: Sendable {
        var maxIterations = 10
        /// Correspondence rejection distance, annealed across iterations.
        var initialRejectionDistance: Float = 0.020
        var finalRejectionDistance: Float = 0.008
        /// Reject correspondences whose normal is near-perpendicular to the
        /// view ray (cos 75°): grazing depth is unreliable.
        var grazingCosine: Float = 0.26
        /// Reject correspondences whose model normal disagrees with the
        /// observed surface normal from the depth map (cos 45°). Projective
        /// association happily matches a side-face sample to a top-surface
        /// pixel; without this check those junk matches exert systematic
        /// wrong-direction torque on the solve.
        var normalCompatibility: Float = 0.7
        /// ARConfidenceLevel raw value; medium and high participate.
        var minimumConfidence: UInt8 = 1
        var huberDelta: Float = 0.004
        var lockRMS: Float = 0.004
        var lockInlierFraction: Float = 0.6
        var lockLatticeMargin: Float = 1.3
        var lostInlierFraction: Float = 0.3
        /// Below this visible fraction the sample is effectively off camera:
        /// the pose is held and the loss clock does not run, because absence
        /// of the build in view is not evidence of a bad fit.
        var offCameraVisibleFraction: Float = 0.2
        /// Seconds of collapsed correspondence before locked degrades to lost.
        var lostGracePeriod: TimeInterval = 1.0
        /// Exponential smoothing factor applied to published poses.
        var poseSmoothing: Float = 0.3
        var studPitch: Float = 0.008
    }

    struct SolveResult: Sendable {
        let worldFromModel: simd_float4x4
        let quality: RegistrationQuality
        /// Fraction of sample points that projected inside the depth image;
        /// distinct from inliers, used to tell "bad pose" from "off camera".
        let visibleFraction: Float
    }

    /// Typical lever-arm length used to express yaw in meters inside the
    /// normal equations, making the observability floor comparable across
    /// all four directions.
    private static let leverScale: Float = 0.05

    private let configuration: Configuration
    private var sample: ModelSurfaceSample?
    private var alignmentID: UUID?
    private var worldFromModel = matrix_identity_float4x4
    private var state: RegistrationState = .unplaced
    private var lastConfidentTimestamp: TimeInterval = 0
    private var trackTask: Task<Void, Never>?

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Installs (or replaces) the fit target. Called at coarse placement and
    /// again after each confirmed step, when the cumulative model grew.
    func setTarget(_ sample: ModelSurfaceSample, coarseWorldFromModel: simd_float4x4, alignmentID: UUID) {
        self.sample = sample
        self.alignmentID = alignmentID
        worldFromModel = coarseWorldFromModel
        // Each target starts without the prior target's confidence clock.
        lastConfidentTimestamp = 0
        state = .coarse
    }

    func stop() {
        trackTask?.cancel()
        trackTask = nil
        state = .unplaced
        sample = nil
        alignmentID = nil
        lastConfidentTimestamp = 0
    }

    /// Consumes depth frames and yields registration updates until the input
    /// stream ends or `stop()` is called. One tracking run at a time.
    func track(frames: AsyncStream<RegistrationFrameInput>) -> AsyncStream<ModelRegistration> {
        trackTask?.cancel()
        return AsyncStream { continuation in
            let task = Task {
                for await frame in frames {
                    guard !Task.isCancelled else { break }
                    if let update = self.process(frame) {
                        continuation.yield(update)
                    }
                }
                continuation.finish()
            }
            trackTask = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Solves one frame against the current target and advances the state
    /// machine. Callers that own the frame loop (RegistrationController, so
    /// verification can observe the same frames) use this directly.
    func process(_ frame: RegistrationFrameInput) -> ModelRegistration? {
        ingest(frame)
    }

    private func ingest(_ frame: RegistrationFrameInput) -> ModelRegistration? {
        guard let sample, let alignmentID, state != .unplaced else { return nil }
        let result = Self.solve(
            sample: sample,
            frame: frame,
            initialWorldFromModel: worldFromModel,
            configuration: configuration
        )

        let quality = result.quality
        let previousState = state
        // An off-camera sample is no evidence of a bad fit: hold the pose
        // and keep the loss clock from running until the build is in view.
        let offCamera = result.visibleFraction < configuration.offCameraVisibleFraction
        if offCamera || quality.inlierFraction >= configuration.lostInlierFraction {
            lastConfidentTimestamp = frame.timestamp
        }

        switch previousState {
        case .unplaced:
            return nil
        case .coarse, .refining, .ambiguous, .locked:
            if quality.inlierFraction < configuration.lostInlierFraction {
                // Momentary occlusion should not drop the lock; sustained
                // collapse should.
                if frame.timestamp - lastConfidentTimestamp > configuration.lostGracePeriod {
                    state = previousState == .coarse ? .coarse : .lost
                }
            } else if quality.rmsResidual <= configuration.lockRMS,
                      quality.inlierFraction >= configuration.lockInlierFraction {
                state = quality.latticeMargin >= configuration.lockLatticeMargin ? .locked : .ambiguous
            } else {
                state = .refining
            }
        case .lost:
            // A recovering fit re-enters through refining.
            if quality.inlierFraction >= configuration.lostInlierFraction {
                state = .refining
            }
        }

        if state != .lost, quality.inlierFraction >= configuration.lostInlierFraction {
            worldFromModel = Self.blend(
                current: worldFromModel,
                target: result.worldFromModel,
                factor: configuration.poseSmoothing
            )
        }

        return ModelRegistration(
            alignmentID: alignmentID,
            worldFromModel: worldFromModel,
            state: state,
            quality: quality,
            fittedStepIndex: sample.stepIndex,
            timestamp: frame.timestamp
        )
    }

    // MARK: - Solver (pure)

    /// Runs the full annealed iteration schedule against one frame and
    /// returns the refined pose plus quality evidence, including the
    /// stud-lattice ambiguity margin.
    static func solve(
        sample: ModelSurfaceSample,
        frame: RegistrationFrameInput,
        initialWorldFromModel: simd_float4x4,
        configuration: Configuration = Configuration()
    ) -> SolveResult {
        var pose = initialWorldFromModel
        let iterations = max(1, configuration.maxIterations)
        // One world-space scratch buffer, reused across every iteration.
        var worldPoints = [SIMD3<Float>](repeating: .zero, count: sample.points.count)
        for iteration in 0..<iterations {
            let progress = iterations == 1 ? 1 : Float(iteration) / Float(iterations - 1)
            let rejection = configuration.initialRejectionDistance
                + (configuration.finalRejectionDistance - configuration.initialRejectionDistance) * progress
            guard let update = iterate(
                sample: sample,
                frame: frame,
                pose: pose,
                rejectionDistance: rejection,
                configuration: configuration,
                worldPoints: &worldPoints
            ) else { break }
            pose = update
        }

        let (quality, visible) = evaluate(
            sample: sample,
            frame: frame,
            pose: pose,
            configuration: configuration
        )
        return SolveResult(worldFromModel: pose, quality: quality, visibleFraction: visible)
    }

    /// One linearized 4-DoF Gauss-Newton step, or nil when correspondence is
    /// too thin to solve.
    private static func iterate(
        sample: ModelSurfaceSample,
        frame: RegistrationFrameInput,
        pose: simd_float4x4,
        rejectionDistance: Float,
        configuration: Configuration,
        worldPoints: inout [SIMD3<Float>]
    ) -> simd_float4x4? {
        let cameraFromWorld = frame.worldFromCamera.inverse
        let cameraPosition = SIMD3(
            frame.worldFromCamera.columns.3.x,
            frame.worldFromCamera.columns.3.y,
            frame.worldFromCamera.columns.3.z
        )
        let rotation = simd_float3x3(
            SIMD3(pose.columns.0.x, pose.columns.0.y, pose.columns.0.z),
            SIMD3(pose.columns.1.x, pose.columns.1.y, pose.columns.1.z),
            SIMD3(pose.columns.2.x, pose.columns.2.y, pose.columns.2.z)
        )

        // Normal equations for δ = (yaw·leverScale, tx, ty, tz).
        var ata = simd_double4x4()
        var atb = SIMD4<Double>()
        var totalWeight = 0.0
        var correspondences = 0
        var pivotAccumulator = SIMD3<Float>()

        // First pass gathers world points to place the yaw pivot at their
        // centroid, decorrelating yaw from translation.
        guard !sample.points.isEmpty else { return nil }
        for index in sample.points.indices {
            let world4 = pose * SIMD4(sample.points[index], 1)
            let world = SIMD3(world4.x, world4.y, world4.z)
            worldPoints[index] = world
            pivotAccumulator += world
        }
        let pivot = pivotAccumulator / Float(worldPoints.count)
        let up = SIMD3<Float>(0, 1, 0)

        for index in sample.points.indices {
            let world = worldPoints[index]
            guard let observed = observedSurface(
                of: world,
                frame: frame,
                cameraFromWorld: cameraFromWorld,
                minimumConfidence: configuration.minimumConfidence
            ) else { continue }

            let normal = normalize(rotation * sample.normals[index])
            // Front-facing with margin: a sample whose surface points away
            // from the camera cannot be the observed surface, and a grazing
            // one measures unreliable depth. (No absolute value — back
            // faces are junk correspondences by construction.)
            let toCamera = normalize(cameraPosition - world)
            guard dot(toCamera, normal) >= configuration.grazingCosine else { continue }
            // A valid observed normal that disagrees is a junk match
            // (side-face sample on a top-surface pixel). An uncomputable
            // normal (edge pixels on thin faces) keeps the point at reduced
            // weight — thin side faces are exactly what constrains x/z.
            var weightScale = 1.0
            if let observedNormal = observed.normal {
                guard dot(normal, observedNormal) >= configuration.normalCompatibility else { continue }
            } else {
                weightScale = 0.5
            }

            let residual = dot(normal, observed.point - world)
            guard abs(residual) <= rejectionDistance else { continue }
            // Point-to-plane distance can be tiny while the actual match is
            // far away in 3D (a side-face sample against a surface elsewhere
            // along the ray); cap the Euclidean gap too.
            guard simd_length(observed.point - world) <= rejectionDistance * 2 else { continue }

            let weight = weightScale * Double(min(1, configuration.huberDelta / max(abs(residual), 1e-6)))
            let lever = cross(up, world - pivot)
            // Yaw is solved in length units (radians × leverScale) so all
            // four directions share one observability scale.
            let jacobian = SIMD4<Double>(
                Double(dot(normal, lever) / Self.leverScale),
                Double(normal.x),
                Double(normal.y),
                Double(normal.z)
            )
            for row in 0..<4 {
                for column in 0..<4 {
                    ata[column][row] += weight * jacobian[row] * jacobian[column]
                }
            }
            atb += jacobian * (weight * Double(residual))
            totalWeight += weight
            correspondences += 1
        }

        guard correspondences >= 12 else { return nil }
        // Observability gate: a direction the visible geometry does not
        // constrain (top-face-only views leave x/z/yaw dark) must receive NO
        // update — otherwise numerical noise integrates into a stud-sized
        // walk across iterations. Gated directions get an identity row so
        // the solve stays well-posed and returns zero for them.
        let informationFloor = 0.02 * totalWeight
        var gated = [false, false, false, false]
        for diagonal in 0..<4 where ata[diagonal][diagonal] < informationFloor {
            gated[diagonal] = true
            for other in 0..<4 {
                ata[other][diagonal] = 0
                ata[diagonal][other] = 0
            }
            ata[diagonal][diagonal] = 1
            atb[diagonal] = 0
        }
        // Levenberg damping keeps a thin normal matrix from exploding the
        // step instead of failing outright.
        for diagonal in 0..<4 {
            ata[diagonal][diagonal] += 1e-9 + 1e-2 * ata[diagonal][diagonal]
        }
        let delta = ata.inverse * atb
        guard delta.x.isFinite, delta.y.isFinite, delta.z.isFinite, delta.w.isFinite else { return nil }

        // Trust region: even observable directions must creep, not jump.
        let yaw = gated[0] ? 0 : max(-0.05, min(0.05, Float(delta.x) / Self.leverScale))
        let translation = SIMD3(
            gated[1] ? 0 : max(-0.005, min(0.005, Float(delta.y))),
            gated[2] ? 0 : max(-0.005, min(0.005, Float(delta.z))),
            gated[3] ? 0 : max(-0.005, min(0.005, Float(delta.w)))
        )
        var yawRotation = matrix_identity_float4x4
        let cosYaw = cos(yaw)
        let sinYaw = sin(yaw)
        yawRotation.columns.0 = SIMD4(cosYaw, 0, -sinYaw, 0)
        yawRotation.columns.2 = SIMD4(sinYaw, 0, cosYaw, 0)

        var toPivot = matrix_identity_float4x4
        toPivot.columns.3 = SIMD4(-pivot, 1)
        var fromPivot = matrix_identity_float4x4
        fromPivot.columns.3 = SIMD4(pivot + translation, 1)
        return fromPivot * yawRotation * toPivot * pose
    }

    /// Final-quality evaluation at the tight rejection distance, plus the
    /// lattice-ambiguity margin of ADR 0009.
    private static func evaluate(
        sample: ModelSurfaceSample,
        frame: RegistrationFrameInput,
        pose: simd_float4x4,
        configuration: Configuration
    ) -> (RegistrationQuality, visibleFraction: Float) {
        let tight = configuration.finalRejectionDistance
        let current = cost(sample: sample, frame: frame, pose: pose, rejection: tight, configuration: configuration)
        guard current.projected > 0 else {
            return (RegistrationQuality.none, 0)
        }

        let rms = current.inliers > 0 ? sqrt(current.squaredInlierSum / Float(current.inliers)) : .infinity
        let inlierFraction = Float(current.inliers) / Float(current.projected)
        let visibleFraction = Float(current.projected) / Float(max(sample.points.count, 1))

        // Alternative hypotheses: ±1 stud along the model's x/z axes, 180°
        // yaw, and 90° yaw for near-square footprints. A fit below the loss
        // floor can never become a lock candidate, so the sweep is skipped
        // and the margin reports 0 — no distinctiveness evidence.
        var margin: Float = 0
        if inlierFraction >= configuration.lostInlierFraction {
            margin = .greatestFiniteMagnitude
            let currentCost = max(current.meanClampedCost, 1e-9)
            for alternative in latticeAlternatives(sample: sample, pose: pose, configuration: configuration) {
                let altCost = cost(
                    sample: sample, frame: frame, pose: alternative,
                    rejection: tight, configuration: configuration
                )
                let ratio: Float
                if altCost.projected < current.projected / 2 {
                    // The alternative mostly leaves the image; it cannot
                    // explain the observation and does not cap the margin.
                    ratio = .greatestFiniteMagnitude
                } else {
                    ratio = altCost.meanClampedCost / currentCost
                }
                margin = min(margin, ratio)
            }
        }

        return (
            RegistrationQuality(
                rmsResidual: rms,
                inlierFraction: inlierFraction,
                latticeMargin: margin
            ),
            visibleFraction
        )
    }

    private struct CostSummary {
        var squaredInlierSum: Float = 0
        var clampedSum: Float = 0
        var inliers = 0
        var projected = 0

        var meanClampedCost: Float {
            projected > 0 ? clampedSum / Float(projected) : .greatestFiniteMagnitude
        }
    }

    private static func cost(
        sample: ModelSurfaceSample,
        frame: RegistrationFrameInput,
        pose: simd_float4x4,
        rejection: Float,
        configuration: Configuration
    ) -> CostSummary {
        let cameraFromWorld = frame.worldFromCamera.inverse
        let cameraPosition = SIMD3(
            frame.worldFromCamera.columns.3.x,
            frame.worldFromCamera.columns.3.y,
            frame.worldFromCamera.columns.3.z
        )
        let rotation = simd_float3x3(
            SIMD3(pose.columns.0.x, pose.columns.0.y, pose.columns.0.z),
            SIMD3(pose.columns.1.x, pose.columns.1.y, pose.columns.1.z),
            SIMD3(pose.columns.2.x, pose.columns.2.y, pose.columns.2.z)
        )
        var summary = CostSummary()
        let clamp = rejection * rejection
        for index in sample.points.indices {
            let world4 = pose * SIMD4(sample.points[index], 1)
            let world = SIMD3(world4.x, world4.y, world4.z)
            let candidateNormal = normalize(rotation * sample.normals[index])
            // Only samples that could be observed at this pose participate;
            // back-facing and grazing samples are invisible, not misfit.
            guard dot(normalize(cameraPosition - world), candidateNormal) >= configuration.grazingCosine else { continue }
            guard let observed = observedSurface(
                of: world,
                frame: frame,
                cameraFromWorld: cameraFromWorld,
                minimumConfidence: configuration.minimumConfidence
            ) else { continue }
            summary.projected += 1
            let residual = dot(candidateNormal, observed.point - world)
            // A valid observed normal that disagrees is evidence of misfit
            // even when the ray distance happens to be small; an
            // uncomputable normal falls back to the distance test alone.
            let normalAgrees = observed.normal.map { dot(candidateNormal, $0) >= configuration.normalCompatibility } ?? true
            if abs(residual) <= rejection, normalAgrees {
                summary.inliers += 1
                summary.squaredInlierSum += residual * residual
                summary.clampedSum += residual * residual
            } else {
                summary.clampedSum += clamp
            }
        }
        return summary
    }

    private static func latticeAlternatives(
        sample: ModelSurfaceSample,
        pose: simd_float4x4,
        configuration: Configuration
    ) -> [simd_float4x4] {
        var alternatives: [simd_float4x4] = []
        let pitch = configuration.studPitch
        for shift in [SIMD3<Float>(pitch, 0, 0), SIMD3(-pitch, 0, 0), SIMD3(0, 0, pitch), SIMD3(0, 0, -pitch)] {
            let world4 = pose * SIMD4(shift, 0)
            var shifted = pose
            shifted.columns.3 += SIMD4(world4.x, world4.y, world4.z, 0)
            alternatives.append(shifted)
        }

        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for point in sample.points {
            minimum = simd_min(minimum, point)
            maximum = simd_max(maximum, point)
        }
        let extent = maximum - minimum
        let centroid = (minimum + maximum) / 2
        var yaws: [Float] = [.pi]
        let planar = max(extent.x, extent.z)
        if planar > 0, abs(extent.x - extent.z) / planar < 0.15 {
            yaws.append(.pi / 2)
        }
        for yaw in yaws {
            var rotation = matrix_identity_float4x4
            let cosYaw = cos(yaw)
            let sinYaw = sin(yaw)
            rotation.columns.0 = SIMD4(cosYaw, 0, -sinYaw, 0)
            rotation.columns.2 = SIMD4(sinYaw, 0, cosYaw, 0)
            var toCentroid = matrix_identity_float4x4
            toCentroid.columns.3 = SIMD4(-centroid, 1)
            var fromCentroid = matrix_identity_float4x4
            fromCentroid.columns.3 = SIMD4(centroid, 1)
            // Rotate about the model centroid, in model frame.
            alternatives.append(pose * fromCentroid * rotation * toCentroid)
        }
        return alternatives
    }

    /// Projects a world point into the depth image and back-projects the
    /// observed depth at that pixel, along with the observed surface normal
    /// from central differences of neighboring depth. The normal is nil —
    /// not a failure — when neighbors are missing or the surface patch is
    /// degenerate (edge pixels on thin faces). Convention matches
    /// `ExpectedDepthRenderer`.
    private static func observedSurface(
        of world: SIMD3<Float>,
        frame: RegistrationFrameInput,
        cameraFromWorld: simd_float4x4,
        minimumConfidence: UInt8
    ) -> (point: SIMD3<Float>, normal: SIMD3<Float>?)? {
        let camera4 = cameraFromWorld * SIMD4(world, 1)
        let depth = -camera4.z
        guard depth > 0 else { return nil }
        let fx = frame.depthIntrinsics[0][0]
        let fy = frame.depthIntrinsics[1][1]
        let cx = frame.depthIntrinsics[2][0]
        let cy = frame.depthIntrinsics[2][1]
        let u = fx * camera4.x / depth + cx
        let v = fy * (-camera4.y) / depth + cy
        let px = Int(u.rounded())
        let py = Int(v.rounded())
        guard px >= 0, px < frame.width, py >= 0, py < frame.height else { return nil }
        let index = py * frame.width + px
        guard frame.confidence[index] >= minimumConfidence else { return nil }

        func backProject(_ x: Int, _ y: Int) -> SIMD3<Float>? {
            guard x >= 0, x < frame.width, y >= 0, y < frame.height else { return nil }
            let observedDepth = frame.depth[y * frame.width + x]
            guard observedDepth.isFinite, observedDepth > 0 else { return nil }
            return SIMD3(
                (Float(x) - cx) / fx * observedDepth,
                -((Float(y) - cy) / fy * observedDepth),
                -observedDepth
            )
        }

        guard let center = backProject(px, py) else { return nil }

        var worldNormal: SIMD3<Float>?
        if let right = backProject(px + 1, py),
           let left = backProject(px - 1, py),
           let below = backProject(px, py + 1),
           let above = backProject(px, py - 1) {
            // Camera-space normal from central differences, oriented toward
            // the camera (+Z faces the camera in ARKit camera space). A
            // patch spanning a depth discontinuity produces a wild normal;
            // treat implausibly stretched patches as no-normal.
            let dx = right - left
            let dy = above - below
            let plausibleSpan = 6 * center.z.magnitude / min(fx, fy)
            if simd_length(dx) < plausibleSpan, simd_length(dy) < plausibleSpan {
                var cameraNormal = cross(dx, dy)
                let lengthSquared = simd_length_squared(cameraNormal)
                if lengthSquared > 1e-12 {
                    cameraNormal /= sqrt(lengthSquared)
                    if cameraNormal.z < 0 { cameraNormal = -cameraNormal }
                    let worldRotation = simd_float3x3(
                        SIMD3(frame.worldFromCamera.columns.0.x, frame.worldFromCamera.columns.0.y, frame.worldFromCamera.columns.0.z),
                        SIMD3(frame.worldFromCamera.columns.1.x, frame.worldFromCamera.columns.1.y, frame.worldFromCamera.columns.1.z),
                        SIMD3(frame.worldFromCamera.columns.2.x, frame.worldFromCamera.columns.2.y, frame.worldFromCamera.columns.2.z)
                    )
                    worldNormal = worldRotation * cameraNormal
                }
            }
        }

        let observedWorld4 = frame.worldFromCamera * SIMD4(center, 1)
        return (
            point: SIMD3(observedWorld4.x, observedWorld4.y, observedWorld4.z),
            normal: worldNormal
        )
    }

    private static func blend(
        current: simd_float4x4,
        target: simd_float4x4,
        factor: Float
    ) -> simd_float4x4 {
        let currentRotation = simd_quatf(simd_float3x3(
            SIMD3(current.columns.0.x, current.columns.0.y, current.columns.0.z),
            SIMD3(current.columns.1.x, current.columns.1.y, current.columns.1.z),
            SIMD3(current.columns.2.x, current.columns.2.y, current.columns.2.z)
        ))
        let targetRotation = simd_quatf(simd_float3x3(
            SIMD3(target.columns.0.x, target.columns.0.y, target.columns.0.z),
            SIMD3(target.columns.1.x, target.columns.1.y, target.columns.1.z),
            SIMD3(target.columns.2.x, target.columns.2.y, target.columns.2.z)
        ))
        let rotation = simd_slerp(currentRotation, targetRotation, factor)
        let translation = simd_mix(
            SIMD3(current.columns.3.x, current.columns.3.y, current.columns.3.z),
            SIMD3(target.columns.3.x, target.columns.3.y, target.columns.3.z),
            SIMD3(repeating: factor)
        )
        var blended = simd_float4x4(rotation)
        blended.columns.3 = SIMD4(translation, 1)
        return blended
    }
}
