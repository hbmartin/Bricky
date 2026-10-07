import Foundation
import simd

/// The placement-level build diff for the current step (M2.3), run in
/// shadow. It wraps the geometric verifier, so its group verdict is the
/// verifier's own, frame for frame: the maps the verifier rendered for a
/// counted frame are reused, and the diff adds only what is per placement.
///
/// On every `placementStride`-th counted frame (offset by `placementPhase`
/// from the verifier's lattice batch), for up to `maxPlacementsPerPass` of
/// the step's placements in turn:
/// - the placement alone (a vertex range; the delta map itself for a
///   one-part step) gives its visible region, where pixels vote support,
///   absence, or unexplained;
/// - its lattice alternatives contest "present as authored" on exclusive
///   evidence, as the verifier's lattice batch does for the whole delta:
///   ±1 stud in x and z, quarter and half turns about its origin, and ±1
///   plate. Plate steps are below what LiDAR resolves, so they are tallied
///   and never acted on. A symmetric turn predicts the same depth and
///   gathers no evidence, so it can never be concluded.
///
/// No alternative is rendered for a placement off the stud lattice.
actor BuildDiffEngine: StepJudging {
    struct Configuration: Sendable {
        var verifier = GeometricStepVerifier.Configuration()
        var placementStride = 3
        var placementPhase = 1
        var maxPlacementsPerPass = 2
        var maxRendersPerPass = 16
        var minimumPlacementEvidence = 30
        var supportFloor: Float = 0.7
        var contraryCeiling: Float = 0.15
        var absenceFloor: Float = 0.5
        var plateHeight: Float = 0.0032
        /// The verifier's 1.5 mm "in front of" margin.
        var frontMargin: Float = 0.0015
        /// With a table, the colour term also reads each placement (M3.2)
        /// and may name a colour mismatch. Nil leaves the diff depth-only.
        var colourTable: ColourTable? = nil
        var colourTerm = ColourAgreementTerm.Configuration()
    }

    private let configuration: Configuration
    private let renderer: ExpectedDepthRenderer
    private let verifier: GeometricStepVerifier
    private var stepID = ""
    private var geometry: StepGeometry?
    private var timeline: DepthGeometry?
    private var evidence: [Int: PlacementEvidence] = [:]
    private var countedFrames = 0
    private var cursor = 0
    private var generation = 0
    private var colourTerm: ColourAgreementTerm?
    /// Per placement, the colour evidence of the passes that voted on it.
    private var colourEvidence: [Int: [ColourAgreementTerm.FrameEvidence]] = [:]
    /// How `ingest` turns the diff into a verdict. Only `.legacyEquivalent`
    /// is ever user-facing; `.placementAware` is logged in shadow.
    var policy: DiffStepVerdictAdapter.Policy = .legacyEquivalent
    private(set) var lastDiff: BuildDiff?
    /// Renders of the most recent per-placement pass, for the budget test.
    private(set) var lastPassRenders = 0

    init(
        configuration: Configuration = Configuration(), renderer: ExpectedDepthRenderer? = nil,
        policy: DiffStepVerdictAdapter.Policy = .legacyEquivalent
    ) throws {
        self.configuration = configuration
        self.policy = policy
        let renderer = try renderer ?? ExpectedDepthRenderer.shared()
        self.renderer = renderer
        var verifierConfiguration = configuration.verifier
        // The colour term reads the tags the verifier renders in its batch.
        if configuration.colourTable != nil { verifierConfiguration.renderColourTags = true }
        verifier = try GeometricStepVerifier(configuration: verifierConfiguration, renderer: renderer)
    }

    func setPolicy(_ policy: DiffStepVerdictAdapter.Policy) {
        self.policy = policy
    }

    func begin(stepID: String, geometry: StepGeometry) async {
        generation += 1
        self.stepID = stepID
        self.geometry = geometry
        timeline = geometry.segments.map { renderer.prepare($0) }
        colourTerm = configuration.colourTable.map { table in
            ColourAgreementTerm(
                table: table, billOfMaterials: ColourTermJudge.billOfMaterials(geometry),
                configuration: configuration.colourTerm
            )
        }
        clear()
        await verifier.begin(stepID: stepID, geometry: geometry)
    }

    func resetEvidence() async {
        generation += 1
        clear()
        await verifier.resetEvidence()
    }

    private func clear() {
        evidence = [:]
        colourEvidence = [:]
        countedFrames = 0
        cursor = 0
        lastDiff = nil
        lastPassRenders = 0
    }

    func ingest(frame: RegistrationFrameInput, registration: ModelRegistration) async throws -> StepVerification {
        let signpost = GeometrySignposts.signposter.beginInterval("BuildDiffIngest")
        var renders = 0
        defer { GeometrySignposts.signposter.endInterval("BuildDiffIngest", signpost, "renders=\(renders)") }
        let started = generation
        let (verification, maps) = try await verifier.ingestReporting(frame: frame, registration: registration)
        guard started == generation else { return verification }
        if let maps, let geometry, let segments = geometry.segments, let timeline, !geometry.deltaPlacements.isEmpty {
            let frameIndex = countedFrames
            countedFrames += 1
            let stride = max(1, configuration.placementStride)
            if frameIndex % stride == configuration.placementPhase % stride {
                renders = try await placementPass(
                    maps: maps, frame: frame, geometry: geometry, segments: segments, timeline: timeline
                )
                guard started == generation else { return verification }
                lastPassRenders = renders
            }
        }
        let diff = makeDiff(group: verification)
        lastDiff = diff
        return DiffStepVerdictAdapter.verdict(for: diff, legacy: verification, policy: policy)
    }

    // MARK: - Per-placement pass

    private struct PlannedRender {
        let placement: Int
        let offset: LatticeOffset?
        let request: DepthRenderRequest
    }

    private func placementPass(
        maps: GeometricStepVerifier.FrameMaps, frame: RegistrationFrameInput, geometry: StepGeometry,
        segments: SegmentedGeometry, timeline: DepthGeometry
    ) async throws -> Int {
        let delta = Array(geometry.deltaPlacements)
        let single = delta.count == 1
        var planned: [PlannedRender] = []
        var chosen: [Int] = []
        for step in 0..<delta.count where chosen.count < configuration.maxPlacementsPerPass {
            let placement = delta[(cursor + step) % delta.count]
            let renders = plan(placement: placement, single: single, viewFromModel: maps.viewFromModel,
                               segments: segments, timeline: timeline, index: geometry.index)
            guard planned.count + renders.count <= configuration.maxRendersPerPass else { break }
            planned.append(contentsOf: renders)
            chosen.append(placement)
        }
        cursor = (cursor + max(1, chosen.count)) % delta.count
        let rendered = planned.isEmpty ? [] : try await renderer.render(
            planned.map(\.request), intrinsics: frame.depthIntrinsics, width: frame.width, height: frame.height
        )
        for placement in chosen {
            let alone = single
                ? maps.delta
                : zip(planned, rendered).first { $0.0.placement == placement && $0.0.offset == nil }?.1
            guard let alone else { continue }
            let alternatives = zip(planned, rendered).compactMap { render, map -> (LatticeOffset, ExpectedDepthMap)? in
                guard render.placement == placement, let offset = render.offset else { return nil }
                return (offset, map)
            }
            vote(placement: placement, alone: alone, alternatives: alternatives, maps: maps, single: single)
        }
        return planned.count
    }

    /// The renders one placement needs this pass: itself (unless the delta
    /// map already is it), then its lattice alternatives.
    private func plan(
        placement: Int, single: Bool, viewFromModel: simd_float4x4, segments: SegmentedGeometry,
        timeline: DepthGeometry, index: PlacementGeometryIndex?
    ) -> [PlannedRender] {
        let range = [segments.vertexRange(placement)]
        var renders: [PlannedRender] = []
        if !single {
            renders.append(PlannedRender(
                placement: placement, offset: nil,
                request: DepthRenderRequest(geometry: timeline, viewFromModel: viewFromModel, ranges: range)
            ))
        }
        guard let index, index.status.indices.contains(placement), index.status[placement].cell != nil else {
            return renders
        }
        let pitch = configuration.verifier.studPitch
        let origin = index.origins[placement]
        let offsets: [LatticeOffset] = [
            LatticeOffset(dx: 1), LatticeOffset(dx: -1), LatticeOffset(dz: 1), LatticeOffset(dz: -1),
            LatticeOffset(quarterTurns: 1), LatticeOffset(quarterTurns: 2),
            LatticeOffset(dy: 1), LatticeOffset(dy: -1)
        ]
        for offset in offsets {
            var transform = matrix_identity_float4x4
            transform.columns.3 = SIMD4(
                Float(offset.dx) * pitch, Float(offset.dy) * configuration.plateHeight, Float(offset.dz) * pitch, 1
            )
            if offset.isRotation {
                transform = transform * Self.yaw(quarterTurns: offset.quarterTurns, about: origin)
            }
            renders.append(PlannedRender(
                placement: placement, offset: offset,
                request: DepthRenderRequest(geometry: timeline, viewFromModel: viewFromModel * transform, ranges: range)
            ))
        }
        return renders
    }

    /// LDraw's yaw convention (x' = cos·x + sin·z, z' = −sin·x + cos·z) in
    /// exact quarter steps, about `origin`.
    static func yaw(quarterTurns: Int, about origin: SIMD3<Float>) -> simd_float4x4 {
        let (sine, cosine): (Float, Float) = switch ((quarterTurns % 4) + 4) % 4 {
        case 1: (1, 0)
        case 2: (0, -1)
        case 3: (-1, 0)
        default: (0, 1)
        }
        var rotation = matrix_identity_float4x4
        rotation.columns.0 = SIMD4(cosine, 0, -sine, 0)
        rotation.columns.2 = SIMD4(sine, 0, cosine, 0)
        var toOrigin = matrix_identity_float4x4
        toOrigin.columns.3 = SIMD4(origin, 1)
        var fromOrigin = matrix_identity_float4x4
        fromOrigin.columns.3 = SIMD4(-origin, 1)
        return toOrigin * rotation * fromOrigin
    }

    private func vote(
        placement: Int, alone: ExpectedDepthMap, alternatives: [(LatticeOffset, ExpectedDepthMap)],
        maps: GeometricStepVerifier.FrameMaps, single: Bool
    ) {
        let tolerance = configuration.verifier.depthTolerance
        let margin = configuration.frontMargin
        let minimumConfidence = configuration.verifier.minimumConfidence
        var record = evidence[placement] ?? PlacementEvidence()
        var visible = false
        var footprint = [Bool](repeating: false, count: colourTerm == nil ? 0 : alone.depth.count)
        for index in alone.depth.indices where alone.depth[index] > 0 {
            let expected = alone.depth[index]
            let behind = maps.completed.depth[index]
            guard behind <= 0 || expected < behind - margin else { continue }
            // Another of the step's placements in front hides this one.
            if !single, maps.delta.depth[index] > 0, maps.delta.depth[index] < expected - margin { continue }
            visible = true
            if !footprint.isEmpty { footprint[index] = true }
            guard maps.observedConfidence[index] >= minimumConfidence else { continue }
            let depth = maps.observedDepth[index]
            guard depth.isFinite, depth > 0 else { continue }
            if abs(depth - expected) <= tolerance {
                record.support += 1
            } else if behind > 0 ? abs(depth - behind) <= tolerance : depth >= expected + configuration.verifier.freeSpaceGap {
                record.absence += 1
            } else {
                record.unexplained += 1
            }
        }
        if visible { record.framesSeen += 1 }
        // The colour of this placement's own visible footprint, eroded as
        // the colour term erodes the whole delta.
        if visible, let colourTerm, let colourFrame = ColourTermJudge.colourFrame(maps) {
            let region = ColourAgreementTerm.eroded(footprint, width: alone.width, height: alone.height)
            var frames = colourEvidence[placement] ?? []
            frames.append(colourTerm.evidence(from: colourFrame, region: region))
            if frames.count > ColourTermJudge.maximumFrames { frames.removeFirst(frames.count - ColourTermJudge.maximumFrames) }
            colourEvidence[placement] = frames
        }
        for (offset, alternative) in alternatives {
            var tally = record.tallies.first { $0.offset == offset } ?? HypothesisTally(offset: offset)
            for index in alone.depth.indices where alone.depth[index] > 0 || alternative.depth[index] > 0 {
                guard maps.observedConfidence[index] >= minimumConfidence else { continue }
                let depth = maps.observedDepth[index]
                guard depth.isFinite, depth > 0 else { continue }
                let behind = maps.completed.depth[index]
                let presentDepth = alone.depth[index]
                let alternativeDepth = alternative.depth[index]
                let presentIsPart = presentDepth > 0 && (behind <= 0 || presentDepth < behind - margin)
                let alternativeIsPart = alternativeDepth > 0 && (behind <= 0 || alternativeDepth < behind - margin)
                let expectedPresent = presentIsPart ? presentDepth : behind
                let expectedAlternative = alternativeIsPart ? alternativeDepth : behind
                guard expectedPresent > 0, expectedAlternative > 0,
                      abs(expectedPresent - expectedAlternative) > tolerance else { continue }
                let fitsPresent = abs(depth - expectedPresent) <= tolerance
                let fitsAlternative = abs(depth - expectedAlternative) <= tolerance
                // As in the verifier: only a distinct part surface is
                // placement evidence, never the shared background.
                let presentDistinct = presentIsPart && (behind <= 0 || behind - presentDepth > tolerance)
                let alternativeDistinct = alternativeIsPart && (behind <= 0 || behind - alternativeDepth > tolerance)
                if fitsPresent, !fitsAlternative, presentDistinct {
                    tally.winsPresent += 1
                } else if fitsAlternative, !fitsPresent, alternativeDistinct {
                    tally.winsAlternative += 1
                }
            }
            if let existing = record.tallies.firstIndex(where: { $0.offset == offset }) {
                record.tallies[existing] = tally
            } else {
                record.tallies.append(tally)
            }
        }
        evidence[placement] = record
    }

    // MARK: - Diff

    static func summary(_ assessment: ColourAssessment) -> PlacementColour {
        let group = assessment.groups.first
        return PlacementColour(
            status: assessment.status.name,
            frames: group?.frames ?? 0,
            authoredDistance: group?.authoredDistance,
            nearestCode: group?.nearestCode,
            nearestDistance: group?.nearestDistance
        )
    }

    private func makeDiff(group: StepVerification) -> BuildDiff {
        let placements = geometry.map { Array($0.deltaPlacements) } ?? []
        return BuildDiff(
            stepID: stepID,
            observations: placements.map { placement in
                var record = evidence[placement] ?? PlacementEvidence()
                if let colourTerm, let frames = colourEvidence[placement] {
                    record.colour = Self.summary(colourTerm.assess(frames))
                }
                return PlacementObservation(
                    placement: placement,
                    state: classify(record, group: group),
                    evidence: record
                )
            },
            framesUsed: countedFrames
        )
    }

    private func classify(_ record: PlacementEvidence, group: StepVerification) -> PlacementState {
        // Undetectable only when the verifier judged the delta so; its
        // detectability before any judged frame is just a starting value.
        if group.verdict == .uncertain(.deltaUndetectable) { return .notObservable(.undetectable) }
        let groupDetectability = group.detectability
        guard record.classified >= configuration.minimumPlacementEvidence else {
            return .notObservable(record.framesSeen == 0 ? .occluded : .insufficientEvidence)
        }
        // A lattice alternative that dominates its contest is a misplacement
        // only under strong detectability, as for the whole-delta verdict.
        let decisive = record.tallies
            .filter { !$0.offset.isVertical }
            .filter { $0.winsPresent + $0.winsAlternative >= configuration.verifier.minimumLatticeEvidence }
            .filter { $0.winsAlternative >= 2 * $0.winsPresent }
            .max { $0.winsAlternative < $1.winsAlternative }
        if let decisive {
            guard groupDetectability == .strong else { return .notObservable(.insufficientEvidence) }
            return decisive.offset.isRotation
                ? .rotated(quarterTurns: decisive.offset.quarterTurns)
                : .displaced(decisive.offset)
        }
        let classified = Float(record.classified)
        let support = Float(record.support) / classified
        let absence = Float(record.absence) / classified
        // Present is the per-placement complete, and as hard to earn
        // (ADR 0008): never under marginal detectability.
        if support >= configuration.supportFloor, absence <= configuration.contraryCeiling {
            guard groupDetectability == .strong else { return .notObservable(.insufficientEvidence) }
            // Depth sees the part where it belongs; the colour term sees
            // another colour the model uses there.
            return record.colour?.disagrees == true ? .colourMismatch : .present
        }
        if absence >= configuration.absenceFloor, absence > support { return .absent }
        return .notObservable(.insufficientEvidence)
    }
}

/// Maps a build diff onto the step verdict (M2.3). `.legacyEquivalent`, the
/// only user-facing policy, returns the verifier's verdict unchanged.
/// `.placementAware` may only take a `complete` away: a placement the diff
/// sees as turned, absent, or displaced makes the step uncertain or
/// misplaced, and one in the wrong colour makes it incomplete. It never
/// makes anything complete.
enum DiffStepVerdictAdapter {
    enum Policy: Sendable {
        case legacyEquivalent
        case placementAware
    }

    static func verdict(for diff: BuildDiff, legacy: StepVerification, policy: Policy) -> StepVerification {
        guard policy == .placementAware, legacy.verdict == .complete else { return legacy }
        for observation in diff.observations {
            switch observation.state {
            case .displaced(let offset) where !offset.isVertical:
                return legacy.replacingVerdict(.misplaced(offsetStuds: SIMD2(offset.dx, offset.dz)))
            case .rotated, .absent:
                return legacy.replacingVerdict(.uncertain(.insufficientEvidence))
            case .colourMismatch:
                return legacy.replacingVerdict(.incomplete)
            default:
                continue
            }
        }
        return legacy
    }
}

extension StepVerification {
    func replacingVerdict(_ verdict: StepVerdict) -> StepVerification {
        StepVerification(
            stepID: stepID,
            verdict: verdict,
            detectability: detectability,
            deltaPixels: deltaPixels,
            framesUsed: framesUsed,
            completeFraction: completeFraction,
            incompleteFraction: incompleteFraction,
            registrationQuality: registrationQuality,
            timestamp: timestamp,
            worldFromModel: worldFromModel,
            worldFromCamera: worldFromCamera
        )
    }
}
