import Foundation

/// How the finalist pass turns per-view rankings into one ordered estimate.
///
/// The rank grammar asks for `uniqueItems`, but the pinned xgrammar ignores
/// that keyword without a warning, so `["B","B","B"]` is legal output. Under
/// the legacy rule one such view gave B 3+2+1 points and could outvote two
/// honest views on its own.
public enum RecoveryVoteRule: String, Codable, CaseIterable, Sendable {
    /// Borda over every emitted position, duplicates included — the rule the
    /// app shipped with until 2026-09. Kept so old evidence replays exactly.
    case bordaLegacy = "borda_legacy"
    /// Borda over each view's ranking with repeated slots removed: the first
    /// occurrence keeps its place and later slots move up. The default.
    case bordaDedup = "borda_dedup"
    /// Sum of each view's log probability per candidate (probe scoring):
    /// how much each view believed, not only its order. Views without
    /// probabilities do not vote.
    case logprob
}

/// One voting view: the slot letters it emitted, in order, and which
/// candidate each slot showed.
public struct RecoveryVoteView<Candidate: Hashable & Sendable>: Sendable {
    public let ranking: [String]
    public let candidateForSlot: [String: Candidate]
    /// Slot letter → probability, when the view was probe-scored.
    public let slotProbabilities: [String: Double]?

    public init(ranking: [String], candidateForSlot: [String: Candidate], slotProbabilities: [String: Double]? = nil) {
        self.ranking = ranking
        self.candidateForSlot = candidateForSlot
        self.slotProbabilities = slotProbabilities
    }
}

public struct RecoveryVoteOutcome<Candidate: Hashable & Sendable>: Sendable {
    /// Every finalist, best first; ties keep finalist order.
    public let ordered: [Candidate]
    public let scores: [Candidate: Int]
    public let certainty: RecoveryCertainty
    public let votingViews: Int
}

/// The one implementation of the finalist vote, shared by the app's
/// `HierarchicalRecoveryEstimator` and `bricky-harness`, which previously
/// carried hand-mirrored copies.
public enum RecoveryVote {
    /// Views that must produce a usable ranking before any estimate is made.
    public static let quorum = 2

    /// Aggregates the views that returned `matched`. Returns nil below
    /// quorum. A slot that maps to no candidate is dropped but keeps its
    /// position, so later candidates keep their true rank. Certainty is how
    /// many views put the same candidate first: 3 is high, 2 medium.
    public static func aggregate<Candidate: Hashable & Sendable>(
        views: [RecoveryVoteView<Candidate>],
        finalists: [Candidate],
        rule: RecoveryVoteRule
    ) -> RecoveryVoteOutcome<Candidate>? {
        if rule == .logprob {
            return aggregateLogProbabilities(views: views, finalists: finalists)
        }
        var ballots: [[(position: Int, candidate: Candidate)]] = []
        for view in views {
            let slots = rule == .bordaDedup ? deduplicated(view.ranking) : view.ranking
            let ballot = slots.enumerated().compactMap { position, slot -> (position: Int, candidate: Candidate)? in
                view.candidateForSlot[slot].map { (position, $0) }
            }
            if !ballot.isEmpty {
                ballots.append(ballot)
            }
        }
        guard ballots.count >= quorum else { return nil }

        var scores: [Candidate: Int] = [:]
        for ballot in ballots {
            for entry in ballot {
                scores[entry.candidate, default: 0] += max(0, finalists.count - entry.position)
            }
        }
        let finalistOrder = Dictionary(finalists.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = finalists.sorted {
            let lhs = scores[$0, default: 0], rhs = scores[$1, default: 0]
            return lhs == rhs ? finalistOrder[$0, default: 0] < finalistOrder[$1, default: 0] : lhs > rhs
        }
        let leaders = ballots.compactMap { $0.first?.candidate }
        let agreement = Dictionary(grouping: leaders, by: { $0 }).values.map(\.count).max() ?? 0
        let certainty: RecoveryCertainty = agreement >= 3 ? .high : (agreement == 2 ? .medium : .low)
        return RecoveryVoteOutcome(ordered: ordered, scores: scores, certainty: certainty, votingViews: ballots.count)
    }

    /// Floor on a view's probability so one confident zero cannot veto.
    static let probabilityFloor = 1e-4

    /// Log-probability pooling across probe-scored views. Scores are
    /// integer-scaled (×1000) log sums so the outcome keeps the Borda type;
    /// certainty comes from the pooled posterior: ≥ 0.8 high, ≥ 0.5 medium.
    /// Those cut points are RECONSTRUCTED; recorded distributions allow
    /// re-deriving them from device evidence.
    static func aggregateLogProbabilities<Candidate: Hashable & Sendable>(
        views: [RecoveryVoteView<Candidate>],
        finalists: [Candidate]
    ) -> RecoveryVoteOutcome<Candidate>? {
        let voting = views.compactMap { view -> [Candidate: Double]? in
            guard let probabilities = view.slotProbabilities else { return nil }
            var byCandidate: [Candidate: Double] = [:]
            for (slot, candidate) in view.candidateForSlot {
                byCandidate[candidate] = probabilities[slot] ?? 0
            }
            return byCandidate
        }
        guard voting.count >= quorum else { return nil }
        var logSums = Dictionary(uniqueKeysWithValues: finalists.map { ($0, 0.0) })
        for view in voting {
            for candidate in finalists {
                logSums[candidate, default: 0] += log(max(view[candidate] ?? 0, probabilityFloor))
            }
        }
        let finalistOrder = Dictionary(finalists.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = finalists.sorted {
            let lhs = logSums[$0, default: 0], rhs = logSums[$1, default: 0]
            return lhs == rhs ? finalistOrder[$0, default: 0] < finalistOrder[$1, default: 0] : lhs > rhs
        }
        let peak = logSums.values.max() ?? 0
        let unnormalized = logSums.mapValues { exp($0 - peak) }
        let total = unnormalized.values.reduce(0, +)
        let top = ordered.first.map { (unnormalized[$0] ?? 0) / max(total, .leastNonzeroMagnitude) } ?? 0
        let certainty: RecoveryCertainty = top >= 0.8 ? .high : (top >= 0.5 ? .medium : .low)
        return RecoveryVoteOutcome(
            ordered: ordered,
            scores: logSums.mapValues { Int(($0 * 1_000).rounded()) },
            certainty: certainty,
            votingViews: voting.count
        )
    }

    static func deduplicated(_ ranking: [String]) -> [String] {
        var seen: Set<String> = []
        return ranking.filter { seen.insert($0).inserted }
    }
}

public extension EvidenceCaptureRecord {
    /// The `camera_metadata` entry a benchmark row carries for this capture:
    /// pinhole intrinsics and the sensor resolution they are expressed in.
    /// One definition for the device writer and the harness, which used to
    /// disagree (replay rows lacked width and height).
    var benchmarkCameraMetadata: [String: Float] {
        var metadata: [String: Float] = [:]
        // Column-major 3×3 intrinsics: fx c0r0, fy c1r1, cx c2r0, cy c2r1.
        if cameraIntrinsics.count >= 9 {
            metadata["fx"] = cameraIntrinsics[0]
            metadata["fy"] = cameraIntrinsics[4]
            metadata["cx"] = cameraIntrinsics[6]
            metadata["cy"] = cameraIntrinsics[7]
        }
        if cameraImageResolution.count >= 2 {
            metadata["width"] = cameraImageResolution[0]
            metadata["height"] = cameraImageResolution[1]
        }
        return metadata
    }
}
