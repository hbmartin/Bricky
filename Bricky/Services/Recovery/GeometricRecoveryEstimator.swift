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
        /// Break an inconclusive ranking by per-placement consistency
        /// (M2.6). Off until device replays show it helps (ADR 0010).
        var consistencyTieBreak = false
        /// The leader's fit must at least reach this score for the
        /// tie-break to trust its pose.
        var tieBreakMinimumScore: Float = 0.3
        var tieBreak = PlacementConsistencyScorer.Configuration()
    }

    struct CandidateScore: Sendable {
        let index: Int
        let worldFromModel: simd_float4x4
        let quality: RegistrationQuality
        /// The ranking score. For a disqualified candidate this is the
        /// sentinel the pose-sanity clamp produced, not a measurement —
        /// `disqualification` is what says so.
        let score: Float
        let unexplainedFraction: Float
        /// Candidate surface with nothing observed at it. Weighed into the
        /// score identically to `unexplainedFraction`, so without it a losing
        /// candidate cannot be told from one that lost the other way.
        let phantomFraction: Float
        let visibleFraction: Float
        let disqualification: FitDisqualification
    }

    private let configuration: Configuration
    private let frame: RegistrationFrameInput
    private let sourceRoot: URL
    private let partPackRoot: URL
    private let renderer: ExpectedDepthRenderer
    /// Optional observer, exactly as `HierarchicalRecoveryEstimator` takes
    /// one: the disabled path costs nothing and recording can never change an
    /// estimate (ADR 0007). Typed as the protocol so this file compiles into
    /// the macOS SyntheticRGBD tool, which cannot link the MLX-backed recorder.
    private let recorder: (any GeometricFitRecording)?
    /// The plan's flattened timeline, when the caller already holds it.
    private let geometry: PlacementGeometry?

    init(
        frame: RegistrationFrameInput,
        sourceRoot: URL,
        partPackRoot: URL,
        configuration: Configuration = Configuration(),
        recorder: (any GeometricFitRecording)? = nil,
        renderer: ExpectedDepthRenderer? = nil,
        geometry: PlacementGeometry? = nil
    ) throws {
        self.frame = frame
        self.sourceRoot = sourceRoot
        self.partPackRoot = partPackRoot
        self.configuration = configuration
        self.recorder = recorder
        self.renderer = try renderer ?? ExpectedDepthRenderer.shared()
        self.geometry = geometry
    }

    /// The placement-consistency winner for an inconclusive ranking, when
    /// the tie-break is on and the leader's fit is sound enough to judge
    /// placements from its pose.
    private func tieBreak(ranked: [CandidateScore], plan: InstructionPlan, geometry: PlacementGeometry) async throws -> Int? {
        guard configuration.consistencyTieBreak, let leader = ranked.first,
              leader.disqualification == .none,
              leader.quality.rmsResidual <= configuration.maxFitRMS,
              leader.score >= configuration.tieBreakMinimumScore else { return nil }
        return try await PlacementConsistencyScorer.tieBreak(
            leader: leader.index,
            leaderWorldFromModel: leader.worldFromModel,
            plan: plan,
            geometry: geometry,
            frame: frame,
            renderer: renderer,
            configuration: configuration.tieBreak
        )
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let duration = start.duration(to: .now)
        return Int(duration.components.seconds) * 1_000 + Int(duration.components.attoseconds / 1_000_000_000_000_000)
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
        // One flatten per estimate: every candidate's cumulative geometry is
        // a prefix of it (M2.0), merged exactly as a per-candidate snapshot
        // used to be, so the scores are unchanged.
        let geometry: PlacementGeometry
        if let provided = self.geometry, provided.segments.placementCount == plan.placementTimeline.count {
            geometry = provided
        } else {
            let engine = LDrawGeometryEngine(sourceRoot: sourceRoot, partPackRoot: partPackRoot)
            geometry = PlacementGeometry(plan: plan, segments: try await engine.segmented(placements: plan.placementTimeline))
        }

        var scored: [Int: CandidateScore] = [:]
        // Which refinement pass first scored each candidate, so a fit record
        // can say when in the coarse-to-fine schedule it was considered.
        var passIndexByCandidate: [Int: Int] = [:]
        var interval = 0..<plan.steps.count
        for passIndex in 0..<configuration.refinementPasses {
            let indices = RecoveryIndexing.evenlySampledIndices(
                count: min(configuration.candidatesPerPass, interval.count),
                range: interval
            )
            var fresh: [(index: Int, snapshot: InstructionGeometrySnapshot)] = []
            for index in indices where scored[index] == nil {
                try Task.checkCancellation()
                fresh.append((index, geometry.cumulativeSnapshot(through: plan.steps[index])))
            }
            for score in try await Self.scoreCandidates(
                candidates: fresh,
                frame: frame,
                coarseWorldFromModel: alignment.transform,
                renderer: renderer,
                configuration: configuration
            ) {
                scored[score.index] = score
                passIndexByCandidate[score.index] = passIndex
            }

            guard let best = scored.values.filter({ interval.contains($0.index) }).max(by: { $0.score < $1.score }) else {
                await recordFits(scored: scored, passIndices: passIndexByCandidate, plan: plan, conclusiveIndex: nil)
                return nil
            }
            if interval.count <= configuration.candidatesPerPass { break }
            let spacing = max(1, interval.count / configuration.candidatesPerPass)
            interval = max(0, best.index - spacing)..<min(plan.steps.count, best.index + spacing + 1)
        }

        let ranked = scored.values.sorted { $0.score > $1.score }
        guard let best = ranked.first,
              Self.isConclusive(best: best, runnerUp: ranked.dropFirst().first, configuration: configuration) else {
            if let winner = try await tieBreak(ranked: ranked, plan: plan, geometry: geometry) {
                await recordFits(scored: scored, passIndices: passIndexByCandidate, plan: plan, conclusiveIndex: winner)
                let others = ranked.filter { $0.index != winner }.prefix(2)
                return RecoveryEstimate(
                    rankedStepIDs: ([winner] + others.map(\.index)).map { RecoveryIndexing.stepID(forIndex: $0, plan: plan) },
                    certainty: .medium,
                    modelRevision: "depth-icp-geometric-v1+pcs1",
                    latencyMilliseconds: Self.milliseconds(since: started),
                    captureIDs: captureIDs,
                    insufficiencyCause: nil,
                    method: .geometric
                )
            }
            // An inconclusive attempt is the interesting one — it is what
            // sent the recovery to the VLM — so it is recorded too.
            await recordFits(scored: scored, passIndices: passIndexByCandidate, plan: plan, conclusiveIndex: nil)
            return nil
        }
        await recordFits(scored: scored, passIndices: passIndexByCandidate, plan: plan, conclusiveIndex: best.index)

        let margin = ranked.dropFirst().first.map { best.score / max($0.score, 0.05) } ?? .greatestFiniteMagnitude
        let duration = started.duration(to: .now)
        let latency = Int(duration.components.seconds) * 1_000
            + Int(duration.components.attoseconds / 1_000_000_000_000_000)
        return RecoveryEstimate(
            rankedStepIDs: ranked.prefix(3).map { RecoveryIndexing.stepID(forIndex: $0.index, plan: plan) },
            certainty: margin >= configuration.highCertaintyMargin ? .high : .medium,
            modelRevision: "depth-icp-geometric-v1",
            latencyMilliseconds: latency,
            captureIDs: captureIDs,
            insufficiencyCause: nil,
            method: .geometric
        )
    }

    /// Hands every scored candidate to the recorder, ordered by step index so
    /// `fits.ndjson` reads in plan order rather than dictionary order.
    private func recordFits(
        scored: [Int: CandidateScore],
        passIndices: [Int: Int],
        plan: InstructionPlan,
        conclusiveIndex: Int?
    ) async {
        guard let recorder, !scored.isEmpty else { return }
        let now = Date()
        let records = scored.keys.sorted().compactMap { index -> GeometricFitRecord? in
            guard let candidate = scored[index] else { return nil }
            return GeometricFitRecord(
                fitVersion: EvidenceSchema.fitVersion,
                fitID: UUID(),
                sessionID: recorder.sessionID,
                passIndex: passIndices[index] ?? 0,
                candidateIndex: index,
                stepID: RecoveryIndexing.stepID(forIndex: index, plan: plan),
                score: candidate.score,
                inlierFraction: candidate.quality.inlierFraction,
                visibleFraction: candidate.visibleFraction,
                unexplainedFraction: candidate.unexplainedFraction,
                phantomFraction: candidate.phantomFraction,
                rmsResidual: candidate.quality.rmsResidual,
                latticeMargin: candidate.quality.latticeMargin,
                worldFromModel: Self.rowMajor(candidate.worldFromModel),
                disqualification: candidate.disqualification,
                conclusive: index == conclusiveIndex,
                createdAt: now
            )
        }
        await recorder.recordFits(records)
    }

    /// simd matrices are column-major; the interchange format is row-major so
    /// a reader can reshape to 4x4 without knowing Swift's convention.
    static func rowMajor(_ matrix: simd_float4x4) -> [Float] {
        (0..<4).flatMap { row in (0..<4).map { column in matrix[column][row] } }
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
    /// Every candidate is solved on the CPU first, then all of them render in
    /// one GPU batch at their solved poses.
    static func scoreCandidates(
        candidates: [(index: Int, snapshot: InstructionGeometrySnapshot)],
        frame: RegistrationFrameInput,
        coarseWorldFromModel: simd_float4x4,
        renderer: ExpectedDepthRenderer,
        configuration: Configuration = Configuration()
    ) async throws -> [CandidateScore] {
        let signpost = GeometrySignposts.signposter.beginInterval("RecoveryScore", id: .exclusive, "\(candidates.count) candidates")
        defer { GeometrySignposts.signposter.endInterval("RecoveryScore", signpost) }
        let observed = frame.rawDepth ?? frame.depth
        let observedConfidence = frame.rawConfidence ?? frame.confidence

        var solved: [(index: Int, snapshot: InstructionGeometrySnapshot, solve: DepthICPTracker.SolveResult)] = []
        for candidate in candidates {
            let sample = ModelSurfaceSampler.sample(candidate.snapshot, stepIndex: candidate.index)
            guard !sample.points.isEmpty else { continue }
            solved.append((candidate.index, candidate.snapshot, DepthICPTracker.solve(
                sample: sample,
                frame: frame,
                initialWorldFromModel: coarseWorldFromModel
            )))
        }
        let expectedMaps = try await renderer.render(
            solved.map { candidate in
                DepthRenderRequest(
                    geometry: renderer.prepare(candidate.snapshot),
                    viewFromModel: frame.worldFromCamera.inverse * candidate.solve.worldFromModel
                )
            },
            intrinsics: frame.depthIntrinsics,
            width: frame.width,
            height: frame.height
        )

        var scores: [CandidateScore] = []
        for (candidate, expected) in zip(solved, expectedMaps) {
            let solve = candidate.solve
            let fit = FitScoring.score(
                solve: solve, expected: expected, observed: observed, confidence: observedConfidence,
                minimumConfidence: configuration.minimumConfidence,
                unexplainedGap: configuration.unexplainedGap, unexplainedWeight: configuration.unexplainedWeight
            )
            let unexplainedFraction = fit.unexplainedFraction
            let phantomFraction = fit.phantomFraction
            var score = fit.score

            // Pose-sanity: disqualify fits that left the build plane or slid
            // far from the user's placement — they matched some other
            // surface, however well. The clamp is what keeps a disqualified
            // candidate from winning; the reason is recorded beside it
            // because the clamped score alone cannot express why.
            let deviation = solve.worldFromModel.columns.3 - coarseWorldFromModel.columns.3
            var disqualification = FitDisqualification.none
            if abs(deviation.y) > configuration.maxVerticalDeviation {
                disqualification = .verticalDeviation
            } else if simd_length(SIMD2(deviation.x, deviation.z)) > configuration.maxHorizontalDeviation {
                disqualification = .horizontalDeviation
            }
            if disqualification != .none {
                score = min(score, -1)
            }
            scores.append(CandidateScore(
                index: candidate.index,
                worldFromModel: solve.worldFromModel,
                quality: solve.quality,
                score: score,
                unexplainedFraction: unexplainedFraction,
                phantomFraction: phantomFraction,
                visibleFraction: solve.visibleFraction,
                disqualification: disqualification
            ))
        }
        return scores
    }
}
