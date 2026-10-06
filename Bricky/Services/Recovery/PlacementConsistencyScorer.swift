import Foundation
import simd

/// Breaks a geometric recovery tie by asking which authored step the
/// observed parts agree with, placement by placement (M2.6).
///
/// Whole-build fits score "step k minus one part" about as well as steps
/// k − 1 and k, so the estimate stays inconclusive and falls through to the
/// VLM. Here each contested placement, from the steps around the leader, is
/// rendered alone at the leader's solved pose:
/// - supported, when depth sits on its surface;
/// - absent, when depth is seen through where it would be;
/// - neutral, when it is hidden or too small to tell.
/// A candidate step predicts every placement up to it present and every
/// later one absent. Candidates rank by contradictions, then explained
/// exceptions, then agreements.
///
/// An absence is "explained" (a part forgotten, not a different step)
/// only when nothing observed as supported rests on it, and at most once
/// per candidate. The winner must rank strictly first, or nothing is
/// concluded.
enum PlacementConsistencyScorer {
    struct Configuration: Sendable {
        /// Steps on either side of the leader that compete.
        var window = 3
        /// Contested placements judged, nearest the leader first.
        var maxContested = 48
        /// Renders per batch, matching the renderer's target pool.
        var batchSize = 16
        var depthTolerance: Float = 0.006
        var minimumPixels = 20
        var supportFloor: Float = 0.6
        var absenceFloor: Float = 0.6
        var minimumConfidence: UInt8 = 1
    }

    enum Observation: Equatable, Sendable {
        case supported
        case absent
        case neutral
    }

    struct Ranking: Equatable {
        let candidate: Int
        let contradictions: Int
        let exceptions: Int
        let agreements: Int
    }

    /// The plan index of the step the placements agree with, or nil when
    /// no candidate is strictly best.
    static func tieBreak(
        leader: Int,
        leaderWorldFromModel: simd_float4x4,
        plan: InstructionPlan,
        geometry: PlacementGeometry,
        frame: RegistrationFrameInput,
        renderer: ExpectedDepthRenderer,
        configuration: Configuration = Configuration()
    ) async throws -> Int? {
        guard !plan.steps.isEmpty else { return nil }
        let candidates = max(0, leader - configuration.window)...min(plan.steps.count - 1, leader + configuration.window)
        let contested = contestedPlacements(plan: plan, candidates: candidates, leader: leader, limit: configuration.maxContested)
        guard !contested.isEmpty else { return nil }
        let observations = try await observe(
            contested, viewFromModel: frame.worldFromCamera.inverse * leaderWorldFromModel,
            geometry: geometry, frame: frame, renderer: renderer, configuration: configuration
        )
        let blockers = { (placement: Int) in geometry.index.blockers(of: placement) }
        // A part seen absent beneath a part seen in place cannot be: the
        // pose or the evidence is wrong, and nothing is concluded from it.
        guard !isImplausible(observations: observations, blockers: blockers) else { return nil }
        let rankings = rank(
            candidates: candidates.map { ($0, plan.steps[$0].cumulativePlacementCount) },
            observations: observations,
            blockers: blockers
        )
        guard let best = rankings.first else { return nil }
        if rankings.count > 1, !isStrictlyBetter(best, rankings[1]) { return nil }
        return best.candidate
    }

    /// The placements whose presence differs between the window's
    /// candidates, nearest the leader's frontier first.
    static func contestedPlacements(plan: InstructionPlan, candidates: ClosedRange<Int>, leader: Int, limit: Int) -> [Int] {
        let lower = plan.steps[candidates.lowerBound].addedPlacementRange.lowerBound
        let upper = plan.steps[candidates.upperBound].cumulativePlacementCount
        guard lower < upper else { return [] }
        let frontier = plan.steps[leader].cumulativePlacementCount
        return Array(lower..<upper)
            .sorted { abs($0 - frontier) < abs($1 - frontier) || (abs($0 - frontier) == abs($1 - frontier) && $0 < $1) }
            .prefix(limit)
            .sorted()
    }

    static func isImplausible(observations: [Int: Observation], blockers: (Int) -> [Int]) -> Bool {
        observations.contains { placement, observed in
            observed == .absent && blockers(placement).contains { observations[$0] == .supported }
        }
    }

    /// Ranks candidates, each with the number of placements it has built,
    /// against observed placements; best first.
    static func rank(
        candidates: [(candidate: Int, built: Int)], observations: [Int: Observation], blockers: (Int) -> [Int]
    ) -> [Ranking] {
        let supported = Set(observations.filter { $0.value == .supported }.map(\.key))
        return candidates.map { candidate, built in
            var contradictions = 0
            var exceptions = 0
            var agreements = 0
            for (placement, observed) in observations.sorted(by: { $0.key < $1.key }) {
                let predictedPresent = placement < built
                switch (observed, predictedPresent) {
                case (.neutral, _):
                    continue
                case (.supported, true), (.absent, false):
                    agreements += 1
                case (.supported, false):
                    contradictions += 1
                case (.absent, true):
                    let bearsLoad = blockers(placement).contains { supported.contains($0) && $0 < built }
                    if !bearsLoad, exceptions == 0 {
                        exceptions += 1
                    } else {
                        contradictions += 1
                    }
                }
            }
            return Ranking(candidate: candidate, contradictions: contradictions, exceptions: exceptions, agreements: agreements)
        }
        // Ties order by candidate only so the result is deterministic; a tie
        // at the top concludes nothing.
        .sorted { isStrictlyBetter($0, $1) || (!isStrictlyBetter($1, $0) && $0.candidate < $1.candidate) }
    }

    static func isStrictlyBetter(_ lhs: Ranking, _ rhs: Ranking) -> Bool {
        if lhs.contradictions != rhs.contradictions { return lhs.contradictions < rhs.contradictions }
        if lhs.exceptions != rhs.exceptions { return lhs.exceptions < rhs.exceptions }
        return lhs.agreements > rhs.agreements
    }

    /// Each placement rendered alone, in batches, and classified by what
    /// depth shows where it would be.
    private static func observe(
        _ placements: [Int], viewFromModel: simd_float4x4, geometry: PlacementGeometry,
        frame: RegistrationFrameInput, renderer: ExpectedDepthRenderer, configuration: Configuration
    ) async throws -> [Int: Observation] {
        let timeline = renderer.prepare(geometry.segments)
        let observed = frame.rawDepth ?? frame.depth
        let confidence = frame.rawConfidence ?? frame.confidence
        var result: [Int: Observation] = [:]
        var start = 0
        while start < placements.count {
            let batch = Array(placements[start..<min(placements.count, start + configuration.batchSize)])
            start += batch.count
            let maps = try await renderer.render(
                batch.map { DepthRenderRequest(
                    geometry: timeline, viewFromModel: viewFromModel, ranges: [geometry.segments.vertexRange($0)]
                ) },
                intrinsics: frame.depthIntrinsics, width: frame.width, height: frame.height
            )
            for (placement, map) in zip(batch, maps) {
                var support = 0
                var absence = 0
                var classified = 0
                for index in map.depth.indices where map.depth[index] > 0 {
                    guard confidence[index] >= configuration.minimumConfidence else { continue }
                    let depth = observed[index]
                    guard depth.isFinite, depth > 0 else { continue }
                    let expected = map.depth[index]
                    // Something nearer than the part hides it: no evidence.
                    if depth < expected - configuration.depthTolerance { continue }
                    classified += 1
                    if abs(depth - expected) <= configuration.depthTolerance {
                        support += 1
                    } else {
                        absence += 1
                    }
                }
                guard classified >= configuration.minimumPixels else {
                    result[placement] = .neutral
                    continue
                }
                let total = Float(classified)
                result[placement] = Float(support) / total >= configuration.supportFloor ? .supported
                    : Float(absence) / total >= configuration.absenceFloor ? .absent
                    : .neutral
            }
        }
        return result
    }
}
