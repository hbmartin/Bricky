import Foundation
import simd

/// Judges the current step's exact authored delta against observed LiDAR
/// depth (ADR 0008). Three hypotheses — complete, incomplete, misplaced by a
/// stud — are scored per pixel of the delta's visible footprint, using the
/// expected renders at the registered pose, and accumulated across frames.
///
/// The verdict rules are asymmetric by construction: `complete` demands
/// strong detectability, a high vote fraction, and near-absent contrary
/// evidence; ties and thin evidence resolve to uncertainty or incomplete,
/// never to complete. Under marginal detectability a complete verdict is
/// blocked entirely until the RGB support term exists to corroborate it.
actor GeometricStepVerifier {
    struct Configuration: Sendable {
        /// Per-pixel agreement tolerance against an expected surface.
        var depthTolerance: Float = 0.006
        /// Observed depth this far beyond the expected delta surface means
        /// the ray passed through empty space where the brick should be.
        var freeSpaceGap: Float = 0.008
        var minimumFrames = 8
        var minimumDeltaPixels = 30
        var strongDeltaPixels = 80
        var strongMedianDelta: Float = 0.006
        var marginalMedianDelta: Float = 0.003
        var completeVoteFloor: Float = 0.7
        var completeContraryCeiling: Float = 0.15
        var incompleteVoteFloor: Float = 0.5
        /// Accumulated exclusive-evidence pixels a lattice alternative needs
        /// before it may block complete or claim misplaced.
        var minimumLatticeEvidence = 30
        /// The four alternative renders run every Nth ingested frame; the
        /// exclusive-evidence votes accumulate across frames, so cadence
        /// trades verdict latency for per-frame render cost.
        var latticeFrameStride = 3
        var minimumConfidence: UInt8 = 1
        var studPitch: Float = 0.008
    }

    private let configuration: Configuration
    private let renderer: ExpectedDepthRenderer

    private var stepID = ""
    private var completedSnapshot: InstructionGeometrySnapshot?
    private var deltaSnapshot: InstructionGeometrySnapshot?

    private static let latticeOffsets: [SIMD2<Int>] = [
        SIMD2(1, 0), SIMD2(-1, 0), SIMD2(0, 1), SIMD2(0, -1)
    ]

    private var framesUsed = 0
    private var completeVotes = 0
    private var incompleteVotes = 0
    private var classifiedVotes = 0
    /// Exclusive-evidence tallies against each lattice alternative, counted
    /// only on pixels where the two hypotheses predict different depth. A
    /// one-stud shift leaves most of a flat top at identical depth; only the
    /// disagreement strips discriminate, so scoring anything else dilutes
    /// the signal into a false "complete".
    private var alternativeWinsComplete = [Int](repeating: 0, count: GeometricStepVerifier.latticeOffsets.count)
    private var alternativeWinsShifted = [Int](repeating: 0, count: GeometricStepVerifier.latticeOffsets.count)
    private var lastDetectability: DeltaDetectability = .undetectable
    private var lastDeltaPixels = 0

    init(configuration: Configuration = Configuration()) throws {
        self.configuration = configuration
        renderer = try ExpectedDepthRenderer()
    }

    /// Installs the step under verification and clears accumulated evidence.
    func begin(
        stepID: String,
        completedSnapshot: InstructionGeometrySnapshot,
        deltaSnapshot: InstructionGeometrySnapshot
    ) {
        self.stepID = stepID
        self.completedSnapshot = completedSnapshot
        self.deltaSnapshot = deltaSnapshot
        resetEvidence()
    }

    func resetEvidence() {
        framesUsed = 0
        completeVotes = 0
        incompleteVotes = 0
        classifiedVotes = 0
        alternativeWinsComplete = [Int](repeating: 0, count: Self.latticeOffsets.count)
        alternativeWinsShifted = [Int](repeating: 0, count: Self.latticeOffsets.count)
        lastDetectability = .undetectable
        lastDeltaPixels = 0
    }

    /// Scores one depth frame under the registered pose and returns the
    /// current cumulative assessment.
    func ingest(
        frame: RegistrationFrameInput,
        registration: ModelRegistration
    ) throws -> StepVerification {
        guard registration.allowsVerification else {
            let reason: UncertainReason = registration.state == .ambiguous
                ? .poseAmbiguous
                : .registrationNotLocked
            return assessment(verdict: .uncertain(reason), registration: registration, timestamp: frame.timestamp)
        }
        guard let completedSnapshot, let deltaSnapshot else {
            return assessment(
                verdict: .uncertain(.insufficientEvidence),
                registration: registration,
                timestamp: frame.timestamp
            )
        }

        // Raw depth is the evidence of record; smoothed depth is only a
        // fallback because temporal smoothing lags freshly placed bricks.
        let observed = frame.rawDepth ?? frame.depth
        let observedConfidence = frame.rawConfidence ?? frame.confidence

        let viewFromModel = frame.worldFromCamera.inverse * registration.worldFromModel
        let completedMap = try renderer.render(
            snapshot: completedSnapshot,
            viewFromModel: viewFromModel,
            intrinsics: frame.depthIntrinsics,
            width: frame.width,
            height: frame.height
        )
        let deltaMap = try renderer.render(
            snapshot: deltaSnapshot,
            viewFromModel: viewFromModel,
            intrinsics: frame.depthIntrinsics,
            width: frame.width,
            height: frame.height
        )

        // Farthest delta surface: where nothing completed sits behind the
        // brick, the honest expected depth change is the ray span through
        // the delta itself, not a fixed optimistic constant that would
        // inflate thin overhanging deltas to strong detectability.
        let deltaBackMap = try renderer.render(
            snapshot: deltaSnapshot,
            viewFromModel: viewFromModel,
            intrinsics: frame.depthIntrinsics,
            width: frame.width,
            height: frame.height,
            surface: .farthest
        )

        // Visible footprint: pixels where the delta is the nearest expected
        // surface (in front of any completed geometry behind it).
        var region: [Int] = []
        var depthChanges: [Float] = []
        for index in deltaMap.depth.indices where deltaMap.depth[index] > 0 {
            let behind = completedMap.depth[index]
            if behind <= 0 || deltaMap.depth[index] < behind - 0.0015 {
                region.append(index)
                let span = max(deltaBackMap.depth[index] - deltaMap.depth[index], 0)
                depthChanges.append(behind > 0 ? behind - deltaMap.depth[index] : span)
            }
        }
        lastDeltaPixels = region.count

        guard region.count >= configuration.minimumDeltaPixels else {
            return assessment(
                verdict: .uncertain(.occludedView),
                registration: registration,
                timestamp: frame.timestamp
            )
        }

        depthChanges.sort()
        let medianChange = depthChanges[depthChanges.count / 2]
        if medianChange < configuration.marginalMedianDelta {
            lastDetectability = .undetectable
            return assessment(
                verdict: .uncertain(.deltaUndetectable),
                registration: registration,
                timestamp: frame.timestamp
            )
        }
        lastDetectability = medianChange >= configuration.strongMedianDelta
            && region.count >= configuration.strongDeltaPixels
            ? .strong
            : .marginal

        // Per-pixel votes on the true delta region.
        let tolerance = configuration.depthTolerance
        for index in region {
            guard observedConfidence[index] >= configuration.minimumConfidence else { continue }
            let depth = observed[index]
            guard depth.isFinite, depth > 0 else { continue }
            let expectedComplete = deltaMap.depth[index]
            let behind = completedMap.depth[index]
            classifiedVotes += 1
            if abs(depth - expectedComplete) <= tolerance {
                completeVotes += 1
            } else if behind > 0 ? abs(depth - behind) <= tolerance : depth >= expectedComplete + configuration.freeSpaceGap {
                incompleteVotes += 1
            }
        }

        // Pairwise likelihood test against each ±1-stud lattice alternative,
        // scored only where the two hypotheses disagree about depth. A win
        // counts only when the observation matches that hypothesis's BRICK
        // surface: matching shared background is absence evidence, not
        // placement evidence — otherwise a fully missing brick reads as
        // "misplaced" because each strip favors whichever hypothesis
        // predicts no brick there.
        // The four alternative renders are the expensive half of ingest; run
        // them on a cadence — the exclusive-evidence votes accumulate across
        // frames either way.
        let runLatticePass = framesUsed.isMultiple(of: max(1, configuration.latticeFrameStride))
        for (slot, offset) in Self.latticeOffsets.enumerated() where runLatticePass {
            var shift = matrix_identity_float4x4
            shift.columns.3 = SIMD4(
                Float(offset.x) * configuration.studPitch,
                0,
                Float(offset.y) * configuration.studPitch,
                1
            )
            let alternativeMap = try renderer.render(
                snapshot: deltaSnapshot,
                viewFromModel: viewFromModel * shift,
                intrinsics: frame.depthIntrinsics,
                width: frame.width,
                height: frame.height
            )
            for index in deltaMap.depth.indices
            where deltaMap.depth[index] > 0 || alternativeMap.depth[index] > 0 {
                guard observedConfidence[index] >= configuration.minimumConfidence else { continue }
                let depth = observed[index]
                guard depth.isFinite, depth > 0 else { continue }
                let behind = completedMap.depth[index]
                let deltaDepth = deltaMap.depth[index]
                let altDepth = alternativeMap.depth[index]
                let completeIsBrick = deltaDepth > 0 && (behind <= 0 || deltaDepth < behind - 0.0015)
                let shiftedIsBrick = altDepth > 0 && (behind <= 0 || altDepth < behind - 0.0015)
                let expectedComplete = completeIsBrick ? deltaDepth : behind
                let expectedShifted = shiftedIsBrick ? altDepth : behind
                guard expectedComplete > 0, expectedShifted > 0,
                      abs(expectedComplete - expectedShifted) > tolerance else { continue }
                let fitsComplete = abs(depth - expectedComplete) <= tolerance
                let fitsShifted = abs(depth - expectedShifted) <= tolerance
                // The matched brick surface must also be distinctive from
                // the local background: the bottom band of a side face sits
                // within tolerance of the bare base, so "matching" it is
                // indistinguishable from matching absence and must not count
                // as placement evidence.
                let completeDistinct = completeIsBrick && (behind <= 0 || behind - deltaDepth > tolerance)
                let shiftedDistinct = shiftedIsBrick && (behind <= 0 || behind - altDepth > tolerance)
                if fitsComplete, !fitsShifted, completeDistinct {
                    alternativeWinsComplete[slot] += 1
                } else if fitsShifted, !fitsComplete, shiftedDistinct {
                    alternativeWinsShifted[slot] += 1
                }
            }
        }

        framesUsed += 1
        return assessment(verdict: verdict(), registration: registration, timestamp: frame.timestamp)
    }

    private func verdict() -> StepVerdict {
        guard framesUsed >= configuration.minimumFrames, classifiedVotes > 0 else {
            return .uncertain(.insufficientEvidence)
        }
        let completeFraction = Float(completeVotes) / Float(classifiedVotes)
        let incompleteFraction = Float(incompleteVotes) / Float(classifiedVotes)

        // Exclusive-evidence dominance against each contested alternative.
        // An alternative with too little disagreement evidence (a shift the
        // view genuinely cannot discriminate) neither blocks nor claims.
        var completeBlocked = false
        var bestMisplacedSlot: Int?
        var bestMisplacedScore: Float = 0
        for slot in Self.latticeOffsets.indices {
            let winsComplete = Float(alternativeWinsComplete[slot])
            let winsShifted = Float(alternativeWinsShifted[slot])
            guard winsComplete + winsShifted >= Float(configuration.minimumLatticeEvidence) else { continue }
            if winsComplete < 2 * winsShifted {
                completeBlocked = true
            }
            if winsShifted >= 2 * winsComplete, winsShifted > bestMisplacedScore {
                bestMisplacedScore = winsShifted
                bestMisplacedSlot = slot
            }
        }
        if let bestMisplacedSlot {
            // Misplaced is a strong claim: under marginal detectability the
            // disagreement strips sit within noise of the tolerance.
            guard lastDetectability == .strong else {
                return .uncertain(.insufficientEvidence)
            }
            return .misplaced(offsetStuds: Self.latticeOffsets[bestMisplacedSlot])
        }

        // Complete is the hardest verdict to earn (ADR 0008): strong
        // detectability only, a dominant vote, near-absent contrary
        // evidence, and clear dominance over every discriminable lattice
        // alternative. Marginal detectability blocks complete until RGB
        // corroboration exists.
        if lastDetectability == .strong,
           !completeBlocked,
           completeFraction >= configuration.completeVoteFloor,
           incompleteFraction <= configuration.completeContraryCeiling {
            return .complete
        }
        if incompleteFraction >= configuration.incompleteVoteFloor,
           incompleteFraction > completeFraction {
            return .incomplete
        }
        return .uncertain(.insufficientEvidence)
    }

    private func assessment(
        verdict: StepVerdict,
        registration: ModelRegistration,
        timestamp: TimeInterval
    ) -> StepVerification {
        StepVerification(
            stepID: stepID,
            verdict: verdict,
            detectability: lastDetectability,
            deltaPixels: lastDeltaPixels,
            framesUsed: framesUsed,
            completeFraction: classifiedVotes > 0 ? Float(completeVotes) / Float(classifiedVotes) : 0,
            incompleteFraction: classifiedVotes > 0 ? Float(incompleteVotes) / Float(classifiedVotes) : 0,
            registrationQuality: registration.quality,
            timestamp: timestamp
        )
    }
}
