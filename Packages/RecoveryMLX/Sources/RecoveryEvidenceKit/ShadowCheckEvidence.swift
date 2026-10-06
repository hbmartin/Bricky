import Foundation

/// One shadow advisor run beside a photo check (Phase 3 M3.4, ADR 0018),
/// appended to a session's `shadow-checks.ndjson`. Its own file: the trace
/// reader decodes `traces.ndjson` strictly, so a new pass kind there would
/// break older readers. Never shown to the user.
public struct ShadowCheckTraceV1: Codable, Sendable, Equatable {
    public static let filename = "shadow-checks.ndjson"
    public static let version = 1

    public var recordVersion = ShadowCheckTraceV1.version
    public var shadowID: UUID
    public var sessionID: UUID
    /// The photo the primary check judged.
    public var captureID: UUID
    /// Plan index of the checked step, as a check trace's slot A (−1 is
    /// step zero).
    public var stepIndex: Int
    /// `foundation_models`.
    public var advisor: String
    /// `guide_camera` or `registered`: the target both models saw.
    public var checkTarget: String
    /// What the user was shown.
    public var primaryVerdict: String
    /// The advisor's own verdict, or nil when it gave none.
    public var standaloneVerdict: String?
    /// `answered`, `failed_<reason>`, `unavailable_model`, `skipped_<reason>`.
    public var standaloneOutcome: String
    public var closedAnswer: String?
    public var closedOutcome: String
    /// The primary verdict after the advisor's only-toward-incomplete merge.
    public var mergedVerdict: String
    public var hadDeltaBox: Bool
    public var latencyMilliseconds: Int
    /// The system model is not pinned: the OS build identifies it.
    public var osBuild: String?
    public var deviceModel: String?
    public var createdAt: Date

    public init(
        shadowID: UUID = UUID(), sessionID: UUID, captureID: UUID, stepIndex: Int, advisor: String, checkTarget: String,
        primaryVerdict: String, standaloneVerdict: String?, standaloneOutcome: String, closedAnswer: String?,
        closedOutcome: String, mergedVerdict: String, hadDeltaBox: Bool, latencyMilliseconds: Int,
        osBuild: String?, deviceModel: String?, createdAt: Date
    ) {
        self.shadowID = shadowID
        self.sessionID = sessionID
        self.captureID = captureID
        self.stepIndex = stepIndex
        self.advisor = advisor
        self.checkTarget = checkTarget
        self.primaryVerdict = primaryVerdict
        self.standaloneVerdict = standaloneVerdict
        self.standaloneOutcome = standaloneOutcome
        self.closedAnswer = closedAnswer
        self.closedOutcome = closedOutcome
        self.mergedVerdict = mergedVerdict
        self.hadDeltaBox = hadDeltaBox
        self.latencyMilliseconds = latencyMilliseconds
        self.osBuild = osBuild
        self.deviceModel = deviceModel
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case recordVersion = "record_version"
        case shadowID = "shadow_id"
        case sessionID = "session_id"
        case captureID = "capture_id"
        case stepIndex = "step_index"
        case advisor
        case checkTarget = "check_target"
        case primaryVerdict = "primary_verdict"
        case standaloneVerdict = "standalone_verdict"
        case standaloneOutcome = "standalone_outcome"
        case closedAnswer = "closed_answer"
        case closedOutcome = "closed_outcome"
        case mergedVerdict = "merged_verdict"
        case hadDeltaBox = "had_delta_box"
        case latencyMilliseconds = "latency_ms"
        case osBuild = "os_build"
        case deviceModel = "device_model"
        case createdAt = "created_at"
    }
}

/// A shadow advisor run scored by `score_results.py` as kind
/// `shadow_check`, written at finalize into `shadow_check.ndjson`. Only
/// device rows from staged declarations on a floor device are evidence for
/// ADR 0018; Mac replays (`bricky-harness fm-shadow`) are informational.
public struct ShadowCheckRowV1: Codable, Sendable, Equatable {
    public static let kind = "shadow_check"
    public static let filename = "shadow_check.ndjson"
    public static let schemaVersion = 1

    public var kind = ShadowCheckRowV1.kind
    public var schemaVersion = ShadowCheckRowV1.schemaVersion
    public var provenance = "device"
    /// The shadow run's id.
    public var fixtureID: String
    public var sessionID: UUID
    public var expectedVerdict: String
    public var primaryVerdict: String
    /// `none` when the advisor gave no verdict.
    public var standaloneVerdict: String
    public var closedAnswer: String?
    public var mergedVerdict: String
    public var advisor: String
    public var checkTarget: String
    public var latencyMilliseconds: Int
    public var deviceModel: String
    public var osBuild: String?
    public var labelKind: VLMCheckRowV1.LabelKind
    public var authoredModelID: String
    public var stepIndex: Int
    public var physicalCase: Bool?
    public var legalUseConfirmed: Bool?

    enum CodingKeys: String, CodingKey {
        case kind
        case schemaVersion = "schema_version"
        case provenance
        case fixtureID = "fixture_id"
        case sessionID = "session_id"
        case expectedVerdict = "expected_verdict"
        case primaryVerdict = "primary_verdict"
        case standaloneVerdict = "standalone_verdict"
        case closedAnswer = "closed_answer"
        case mergedVerdict = "merged_verdict"
        case advisor
        case checkTarget = "check_target"
        case latencyMilliseconds = "latency_ms"
        case deviceModel = "device_model"
        case osBuild = "os_build"
        case labelKind = "label_kind"
        case authoredModelID = "authored_model_id"
        case stepIndex = "step_index"
        case physicalCase = "physical_case"
        case legalUseConfirmed = "legal_use_confirmed"
    }

    /// One row per shadow run in a labeled session; unlabeled sessions write
    /// nothing, as for `vlm_check`. The expected verdict uses the check's
    /// rule: step index `i` is complete once `i + 1` steps are.
    public static func deviceRows(session: EvidenceSessionFile, shadows: [ShadowCheckTraceV1]) -> [ShadowCheckRowV1] {
        let truth = session.groundTruth
        let labelKind: VLMCheckRowV1.LabelKind
        switch truth.kind {
        case .staged: labelKind = .staged
        case .confirmed: labelKind = .confirmed
        case .unlabeled: return []
        }
        guard let count = truth.expectedCompletedCount else { return [] }
        return shadows.map { shadow in
            ShadowCheckRowV1(
                fixtureID: shadow.shadowID.uuidString,
                sessionID: session.sessionID,
                expectedVerdict: count >= shadow.stepIndex + 1 ? "complete" : "incomplete",
                primaryVerdict: shadow.primaryVerdict,
                standaloneVerdict: shadow.standaloneVerdict ?? "none",
                closedAnswer: shadow.closedAnswer,
                mergedVerdict: shadow.mergedVerdict,
                advisor: shadow.advisor,
                checkTarget: shadow.checkTarget,
                latencyMilliseconds: shadow.latencyMilliseconds,
                deviceModel: session.deviceModel,
                osBuild: shadow.osBuild ?? session.osBuild,
                labelKind: labelKind,
                authoredModelID: session.authoredModelID.uuidString,
                stepIndex: shadow.stepIndex,
                physicalCase: session.staged?.physicalCase,
                legalUseConfirmed: session.staged?.legalUseConfirmed
            )
        }
    }
}
