import Foundation

/// A decoded model decision, independent of how its JSON was spaced.
/// `status`/`ranking` for rank calls, `result` for step checks.
public struct ReplayDecision: Codable, Sendable, Equatable {
    public let status: String?
    public let ranking: [String]?
    public let result: String?

    public init(status: String? = nil, ranking: [String]? = nil, result: String? = nil) {
        self.status = status
        self.ranking = ranking
        self.result = result
    }

    /// Nil for output that is not a decodable rank or check object.
    public init?(rawOutput: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(rawOutput.utf8)) as? [String: Any] else {
            return nil
        }
        let status = object["status"] as? String
        let ranking = object["ranking"] as? [String]
        let result = object["result"] as? String
        guard status != nil || result != nil else { return nil }
        self.init(status: status, ranking: ranking, result: result)
    }
}

/// The pure parts of replay: what a replayed call decided, whether that
/// decision was right, and what it would have cost the estimate. Kept here,
/// not in the harness, so it is tested without weights.
public enum ReplayAggregation {
    /// Replay compares decisions, not bytes: decoders that differ only in
    /// whitespace (`legacy` vs `feed_all`) make the same decision.
    public static func decisionsMatch(_ lhs: ReplayDecision?, _ rhs: ReplayDecision?) -> Bool {
        lhs != nil && lhs == rhs
    }

    /// The slot letter holding the expected step on this call's board, or nil
    /// when the truth was not among the candidates (a hierarchy miss, not a
    /// ranking error).
    public static func truthSlot(row: EvidenceTraceRow, expectedStepID: String?) -> String? {
        guard let expectedStepID else { return nil }
        return row.candidateStepIDs.first(where: { $0.value == expectedStepID })?.key
    }

    public struct PassOutcome: Codable, Sendable, Equatable {
        public let truthSlot: String?
        public let chosenSlot: String?
        /// nil when the session has no ground truth.
        public let truthInCandidates: Bool?
        /// nil when unlabeled or when the truth was not a candidate.
        public let top1Correct: Bool?

        enum CodingKeys: String, CodingKey {
            case truthSlot = "truth_slot"
            case chosenSlot = "chosen_slot"
            case truthInCandidates = "truth_in_candidates"
            case top1Correct = "top1_correct"
        }
    }

    public static func passOutcome(row: EvidenceTraceRow, decision: ReplayDecision?, expectedStepID: String?) -> PassOutcome {
        let truth = truthSlot(row: row, expectedStepID: expectedStepID)
        // An "insufficient" answer chose nothing, whatever its ranking says.
        let chosen = decision?.status == "matched" ? decision?.ranking?.first : nil
        let labeled = expectedStepID != nil
        return PassOutcome(
            truthSlot: truth,
            chosenSlot: chosen,
            truthInCandidates: labeled ? truth != nil : nil,
            top1Correct: truth.map { chosen == $0 }
        )
    }

    /// The correct verdict for a step-check trace: the checked step is
    /// complete when the session's labeled completed-step count reaches it.
    /// Candidate indices are plan-array indices (−1 is step zero), so step
    /// index `i` is complete once `i + 1` steps are.
    public static func expectedCheckVerdict(row: EvidenceTraceRow, expectedCompletedCount: Int?) -> String? {
        guard let expectedCompletedCount, let index = row.candidateStepIndices["A"] else { return nil }
        return expectedCompletedCount >= index + 1 ? "complete" : "incomplete"
    }

    /// What `latency_ms` on a replay row sums.
    public enum LatencyScope: String, Sendable {
        /// Every replayed call: the whole hierarchy's inference cost.
        case allPasses = "inference_all_passes"
        /// Only the finalist calls, when the earlier passes were not replayed.
        case finalistsOnly = "inference_finalists_only"
    }

    /// What a session's replay ran: the summed latency and the number of
    /// calls behind it, kept together so a row's `vlm_calls` always counts
    /// the calls its `latency_ms` adds up.
    public struct CallTally: Sendable, Equatable {
        public private(set) var latencyMilliseconds = 0
        public private(set) var calls = 0

        public init() {}

        public mutating func add(latencyMilliseconds: Int) {
            self.latencyMilliseconds += latencyMilliseconds
            calls += 1
        }
    }
}
