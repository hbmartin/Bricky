import Foundation
import simd

/// Estimates which authored step the physical build matches by fitting
/// candidate cumulative meshes to one captured depth frame (ADR 0010). Each
/// candidate is ICP-fit from the manual alignment and scored two-sided:
/// how well the candidate's surface is explained by depth, minus how much
/// observed structure sits in front of it (a smaller candidate fits inside a
/// larger build perfectly — only the unexplained-scene term separates them).
/// Inconclusive results return nil so the composite estimator can fall back
/// to the VLM path; the geometric path never guesses.
actor GeometricRecoveryEstimator {
    struct Configuration: Sendable {
        /// A candidate below this score can never conclude the estimate.
        var scoreFloor: Float = 0.45
        /// The leader must beat the runner-up by this factor to conclude.
        var conclusiveMargin: Float = 1.2
        /// Margin at which certainty is high rather than medium.
        var highCertaintyMargin: Float = 1.5
        var maxFitRMS: Float = 0.006
        /// Observed depth this far in front of the candidate surface is
        /// structure the candidate cannot explain; this far behind it means
        /// the candidate predicts a surface that is not there (phantom).
        /// Both weigh against the score with the same factor.
        var unexplainedGap: Float = 0.012
        var unexplainedWeight: Float = 1.5
        /// The ghost was placed on the build plane, so a fit that sinks or
        /// climbs vertically is fitting the wrong surface (an empty table
        /// lets 4-DoF ICP drop a candidate's top face onto the tabletop);
        /// horizontal drift is bounded by how coarsely users place ghosts.
        var maxVerticalDeviation: Float = 0.008
        var maxHorizontalDeviation: Float = 0.04
        var minimumConfidence: UInt8 = 1
        var refinementPasses = 3
        var candidatesPerPass = 8
    }

    struct CandidateScore: Sendable {
        let index: Int
        let worldFromModel: simd_float4x4
        let quality: RegistrationQuality
        let score: Float
        let unexplainedFraction: Float
    }

    private let configuration: Configuration
    private let frame: RegistrationFrameInput
    private let sourceRoot: URL
    private let partPackRoot: URL
    private let renderer: ExpectedDepthRenderer

    init(
        frame: RegistrationFrameInput,
        sourceRoot: URL,
        partPackRoot: URL,
        configuration: Configuration = Configuration()
    ) throws {
        self.frame = frame
        self.sourceRoot = sourceRoot
        self.partPackRoot = partPackRoot
        self.configuration = configuration
        renderer = try ExpectedDepthRenderer()
    }

    /// Returns a conclusive estimate or nil. Step zero (nothing built) has no
    /// geometry to fit and is deliberately left to the VLM fallback.
    func estimate(
        model plan: InstructionPlan,
        alignment: ARAlignment,
        captureIDs: [UUID]
    ) async throws -> RecoveryEstimate? {
        guard !plan.steps.isEmpty else { return nil }
        let started = ContinuousClock.now
        let engine = LDrawGeometryEngine(sourceRoot: sourceRoot, partPackRoot: partPackRoot)

        var scored: [Int: CandidateScore] = [:]
        var interval = 0..<plan.steps.count
        for _ in 0..<configuration.refinementPasses {
            let indices = HierarchicalRecoveryEstimator.evenlySampledIndices(
                count: min(configuration.candidatesPerPass, interval.count),
                range: interval
            )
            var fresh: [(index: Int, snapshot: InstructionGeometrySnapshot)] = []
            for index in indices where scored[index] == nil {
                try Task.checkCancellation()
                let placements = Array(plan.cumulativePlacements(through: plan.steps[index]))
                fresh.append((index, try await engine.snapshot(placements: placements)))
            }
            for score in try Self.scoreCandidates(
                candidates: fresh,
                frame: frame,
                coarseWorldFromModel: alignment.transform,
                renderer: renderer,
                configuration: configuration
            ) {
                scored[score.index] = score
            }

            guard let best = scored.values.filter({ interval.contains($0.index) }).max(by: { $0.score < $1.score }) else {
                return nil
            }
            if interval.count <= configuration.candidatesPerPass { break }
            let spacing = max(1, interval.count / configuration.candidatesPerPass)
            interval = max(0, best.index - spacing)..<min(plan.steps.count, best.index + spacing + 1)
        }

        let ranked = scored.values.sorted { $0.score > $1.score }
        guard let best = ranked.first,
              Self.isConclusive(best: best, runnerUp: ranked.dropFirst().first, configuration: configuration) else {
            return nil
        }

        let margin = ranked.dropFirst().first.map { best.score / max($0.score, 0.05) } ?? .greatestFiniteMagnitude
        let duration = started.duration(to: .now)
        let latency = Int(duration.components.seconds) * 1_000
            + Int(duration.components.attoseconds / 1_000_000_000_000_000)
        return RecoveryEstimate(
            rankedStepIDs: ranked.prefix(3).map { HierarchicalRecoveryEstimator.stepID(forIndex: $0.index, plan: plan) },
            certainty: margin >= configuration.highCertaintyMargin ? .high : .medium,
            modelRevision: "depth-icp-geometric-v1",
            latencyMilliseconds: latency,
            captureIDs: captureIDs,
            insufficiencyCause: nil,
            method: .geometric
        )
    }

    static func isConclusive(
        best: CandidateScore,
        runnerUp: CandidateScore?,
        configuration: Configuration = Configuration()
    ) -> Bool {
        guard best.score >= configuration.scoreFloor,
              best.quality.rmsResidual <= configuration.maxFitRMS else { return false }
        guard let runnerUp else { return true }
        return best.score >= configuration.conclusiveMargin * max(runnerUp.score, 0.05)
    }

    /// Fits and scores each candidate against the frame. Pure with respect to
    /// its inputs; the estimator's plan/engine glue stays thin above it.
    static func scoreCandidates(
        candidates: [(index: Int, snapshot: InstructionGeometrySnapshot)],
        frame: RegistrationFrameInput,
        coarseWorldFromModel: simd_float4x4,
        renderer: ExpectedDepthRenderer,
        configuration: Configuration = Configuration()
    ) throws -> [CandidateScore] {
        let observed = frame.rawDepth ?? frame.depth
        let observedConfidence = frame.rawConfidence ?? frame.confidence
        var scores: [CandidateScore] = []
        for candidate in candidates {
            let sample = ModelSurfaceSampler.sample(candidate.snapshot, stepIndex: candidate.index)
            guard !sample.points.isEmpty else { continue }
            let solve = DepthICPTracker.solve(
                sample: sample,
                frame: frame,
                initialWorldFromModel: coarseWorldFromModel
            )

            let expected = try renderer.render(
                snapshot: candidate.snapshot,
                viewFromModel: frame.worldFromCamera.inverse * solve.worldFromModel,
                intrinsics: frame.depthIntrinsics,
                width: frame.width,
                height: frame.height
            )
            var covered = 0
            var unexplained = 0
            var phantom = 0
            for index in expected.depth.indices where expected.depth[index] > 0 {
                guard observedConfidence[index] >= configuration.minimumConfidence else { continue }
                let depth = observed[index]
                guard depth.isFinite, depth > 0 else { continue }
                covered += 1
                if depth < expected.depth[index] - configuration.unexplainedGap {
                    unexplained += 1
                } else if depth > expected.depth[index] + configuration.unexplainedGap {
                    phantom += 1
                }
            }
            let unexplainedFraction = covered > 0 ? Float(unexplained) / Float(covered) : 1
            let phantomFraction = covered > 0 ? Float(phantom) / Float(covered) : 1
            var score = solve.quality.inlierFraction
                * min(1, solve.visibleFraction * 2)
                - configuration.unexplainedWeight * (unexplainedFraction + phantomFraction)

            // Pose-sanity: disqualify fits that left the build plane or slid
            // far from the user's placement — they matched some other
            // surface, however well.
            let deviation = solve.worldFromModel.columns.3 - coarseWorldFromModel.columns.3
            if abs(deviation.y) > configuration.maxVerticalDeviation
                || simd_length(SIMD2(deviation.x, deviation.z)) > configuration.maxHorizontalDeviation {
                score = min(score, -1)
            }
            scores.append(CandidateScore(
                index: candidate.index,
                worldFromModel: solve.worldFromModel,
                quality: solve.quality,
                score: score,
                unexplainedFraction: unexplainedFraction
            ))
        }
        return scores
    }
}
