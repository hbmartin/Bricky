import Foundation
import simd

/// A ghost pose offered to the user, never applied without their tap (M2.7,
/// ADR 0009 amendment).
struct SuggestedPlacement: Sendable, Equatable {
    let worldFromModel: simd_float4x4
    let score: Float
    /// The best competing pose's score, for the margin the proposal cleared.
    let runnerUpScore: Float?
    let quality: RegistrationQuality
}

enum SuggestionOutcome: Sendable, Equatable {
    case proposal(SuggestedPlacement)
    case noProposal(NoProposalReason)
}

enum NoProposalReason: Sendable, Equatable {
    /// Nothing is built yet, so there is no geometry to fit.
    case nothingBuilt
    /// Nothing stands on the surface under the reticle.
    case noBlob
    /// No pose fit the depth to registration's lock standard.
    case poorFit
    /// More than one pose fits about as well: the user must choose.
    case ambiguous(margin: Float)
}

/// Proposes where the ghost could go, from the depth under the reticle
/// (M2.7). Geometry only, and only a proposal: the user accepts or places
/// the ghost themselves, and registration starts from whatever they
/// confirm (CONTRIBUTING: never claim automatic registration).
///
/// 1. Flood-fill the blob standing more than 3 mm above the support plane,
///    from the reticle's depth pixel (or the nearest blob pixel near it).
/// 2. Seed yaws from the blob's principal axis against the build's own, in
///    all four quarter turns, centred on the blob.
/// 3. Solve each seed with the registration tracker's ICP and score it
///    two-sided (`FitScoring`, as recovery does).
/// 4. Drop near-duplicate poses (within a stud and 20°).
/// 5. Propose only a fit at lock standard that beats every other pose by
///    1.2×.
enum SuggestedPlacementEstimator {
    struct Configuration: Sendable {
        var blobHeight: Float = 0.003
        /// Neighbouring depth pixels further apart than this are different
        /// objects.
        var depthContinuity: Float = 0.01
        var minimumBlobPixels = 60
        /// Depth pixels around the reticle searched for the blob.
        var searchRadius = 8
        var duplicateTranslation: Float = 0.008
        var duplicateYawDegrees: Float = 20
        var proposalMargin: Float = 1.2
        var lockRMS: Float = 0.004
        var lockInliers: Float = 0.6
        var lockLatticeMargin: Float = 1.3
        var minimumConfidence: UInt8 = 1
        var unexplainedGap: Float = 0.012
        var unexplainedWeight: Float = 1.5
    }

    struct Candidate {
        let worldFromModel: simd_float4x4
        let score: Float
        let quality: RegistrationQuality
    }

    static func suggest(
        frame: RegistrationFrameInput,
        reticle: SIMD2<Int>,
        planeHeight: Float,
        build: InstructionGeometrySnapshot,
        renderer: ExpectedDepthRenderer,
        configuration: Configuration = Configuration()
    ) async throws -> SuggestionOutcome {
        let sample = ModelSurfaceSampler.sample(build, stepIndex: 0)
        guard !sample.points.isEmpty else { return .noProposal(.nothingBuilt) }
        let blob = blobPoints(frame: frame, reticle: reticle, planeHeight: planeHeight, configuration: configuration)
        guard blob.count >= configuration.minimumBlobPixels else { return .noProposal(.noBlob) }

        let candidates = try await fits(
            frame: frame, blob: blob, planeHeight: planeHeight, build: build, sample: sample,
            renderer: renderer, configuration: configuration
        )
        let distinct = deduplicated(candidates.sorted { $0.score > $1.score }, configuration: configuration)
        guard let best = distinct.first,
              best.quality.rmsResidual <= configuration.lockRMS,
              best.quality.inlierFraction >= configuration.lockInliers,
              best.quality.latticeMargin >= configuration.lockLatticeMargin else {
            return .noProposal(.poorFit)
        }
        let runnerUp = distinct.dropFirst().first?.score
        let margin = best.score / max(runnerUp ?? 0, 0.05)
        guard margin >= configuration.proposalMargin else { return .noProposal(.ambiguous(margin: margin)) }
        return .proposal(SuggestedPlacement(
            worldFromModel: best.worldFromModel, score: best.score, runnerUpScore: runnerUp, quality: best.quality
        ))
    }

    /// One solved, scored fit per quarter-turn seed.
    static func fits(
        frame: RegistrationFrameInput, blob: [SIMD3<Float>], planeHeight: Float, build: InstructionGeometrySnapshot,
        sample: ModelSurfaceSample, renderer: ExpectedDepthRenderer, configuration: Configuration
    ) async throws -> [Candidate] {
        let blobAxis = principalAngle(blob.map { SIMD2($0.x, $0.z) })
        let blobCentre = blob.reduce(SIMD3<Float>.zero, +) / Float(blob.count)
        let modelPoints = sample.points.map { SIMD2($0.x, $0.z) }
        let modelAxis = principalAngle(modelPoints)
        let modelCentre = modelPoints.reduce(SIMD2<Float>.zero, +) / Float(modelPoints.count)
        let geometry = renderer.prepare(build)

        var candidates: [Candidate] = []
        for turn in 0..<4 {
            let yaw = blobAxis - modelAxis + Float(turn) * .pi / 2
            let rotation = simd_float4x4(simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)))
            let rotatedCentre = rotation * SIMD4(modelCentre.x, 0, modelCentre.y, 1)
            var seed = rotation
            seed.columns.3 = SIMD4(blobCentre.x - rotatedCentre.x, planeHeight, blobCentre.z - rotatedCentre.z, 1)
            let solve = DepthICPTracker.solve(sample: sample, frame: frame, initialWorldFromModel: seed)
            let expected = try await renderer.render(
                [DepthRenderRequest(geometry: geometry, viewFromModel: frame.worldFromCamera.inverse * solve.worldFromModel)],
                intrinsics: frame.depthIntrinsics, width: frame.width, height: frame.height
            )[0]
            let fit = FitScoring.score(
                solve: solve, expected: expected,
                observed: frame.rawDepth ?? frame.depth, confidence: frame.rawConfidence ?? frame.confidence,
                minimumConfidence: configuration.minimumConfidence,
                unexplainedGap: configuration.unexplainedGap, unexplainedWeight: configuration.unexplainedWeight
            )
            candidates.append(Candidate(worldFromModel: solve.worldFromModel, score: fit.score, quality: solve.quality))
        }
        return candidates
    }

    /// World points of the connected region standing above the plane under
    /// the reticle.
    static func blobPoints(
        frame: RegistrationFrameInput, reticle: SIMD2<Int>, planeHeight: Float, configuration: Configuration
    ) -> [SIMD3<Float>] {
        let depth = frame.depth
        let width = frame.width, height = frame.height
        guard width > 0, height > 0 else { return [] }
        func world(_ x: Int, _ y: Int) -> SIMD3<Float>? {
            let index = y * width + x
            guard frame.confidence[index] >= configuration.minimumConfidence else { return nil }
            let z = depth[index]
            guard z.isFinite, z > 0 else { return nil }
            let intrinsics = frame.depthIntrinsics
            // Image y runs down; camera y runs up and the camera looks along −z.
            let camera = SIMD4<Float>(
                (Float(x) - intrinsics[2][0]) / intrinsics[0][0] * z,
                -(Float(y) - intrinsics[2][1]) / intrinsics[1][1] * z,
                -z, 1
            )
            let point = frame.worldFromCamera * camera
            return SIMD3(point.x, point.y, point.z)
        }
        func above(_ x: Int, _ y: Int) -> Bool {
            guard let point = world(x, y) else { return false }
            return point.y > planeHeight + configuration.blobHeight
        }
        var start: SIMD2<Int>?
        search: for radius in 0...configuration.searchRadius {
            for dy in -radius...radius {
                for dx in -radius...radius where max(abs(dx), abs(dy)) == radius {
                    let x = reticle.x + dx, y = reticle.y + dy
                    if (0..<width).contains(x), (0..<height).contains(y), above(x, y) {
                        start = SIMD2(x, y)
                        break search
                    }
                }
            }
        }
        guard let start else { return [] }
        var visited = Set<Int>([start.y * width + start.x])
        var frontier = [start]
        var points: [SIMD3<Float>] = []
        while let pixel = frontier.popLast() {
            guard let point = world(pixel.x, pixel.y) else { continue }
            points.append(point)
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let x = pixel.x + dx, y = pixel.y + dy
                guard (0..<width).contains(x), (0..<height).contains(y) else { continue }
                let index = y * width + x
                guard !visited.contains(index), above(x, y),
                      abs(depth[index] - depth[pixel.y * width + pixel.x]) < configuration.depthContinuity else { continue }
                visited.insert(index)
                frontier.append(SIMD2(x, y))
            }
        }
        return points
    }

    /// The angle of the dominant axis of x/z points, in radians, measured
    /// as LDraw yaw is (from +x toward −z).
    static func principalAngle(_ points: [SIMD2<Float>]) -> Float {
        guard !points.isEmpty else { return 0 }
        let mean = points.reduce(SIMD2<Float>.zero, +) / Float(points.count)
        var xx: Float = 0, xz: Float = 0, zz: Float = 0
        for point in points {
            let d = point - mean
            xx += d.x * d.x
            xz += d.x * d.y
            zz += d.y * d.y
        }
        // The rotation about +y that carries +x onto the major axis.
        return -0.5 * atan2(2 * xz, xx - zz)
    }

    private static func deduplicated(_ sorted: [Candidate], configuration: Configuration) -> [Candidate] {
        var kept: [Candidate] = []
        for candidate in sorted {
            let duplicate = kept.contains { other in
                let translation = simd_distance(
                    SIMD3(candidate.worldFromModel.columns.3.x, candidate.worldFromModel.columns.3.y, candidate.worldFromModel.columns.3.z),
                    SIMD3(other.worldFromModel.columns.3.x, other.worldFromModel.columns.3.y, other.worldFromModel.columns.3.z)
                )
                let yaw = abs(yawDifferenceDegrees(candidate.worldFromModel, other.worldFromModel))
                return translation <= configuration.duplicateTranslation && yaw <= configuration.duplicateYawDegrees
            }
            if !duplicate { kept.append(candidate) }
        }
        return kept
    }

    /// Signed yaw difference in degrees, wrapped to (−180, 180].
    static func yawDifferenceDegrees(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
        let yawA = atan2(-a.columns.0.z, a.columns.0.x)
        let yawB = atan2(-b.columns.0.z, b.columns.0.x)
        var difference = (yawA - yawB) * 180 / .pi
        while difference > 180 { difference -= 360 }
        while difference <= -180 { difference += 360 }
        return difference
    }
}
