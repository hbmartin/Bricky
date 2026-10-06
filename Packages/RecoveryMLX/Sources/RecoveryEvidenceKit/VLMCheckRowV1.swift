import Foundation

/// One step check scored by `score_results.py` as kind `vlm_check`, written
/// on device into a session's `check.ndjson`. The harness writes the same
/// kind from Mac replays (provenance `replay`); only device rows from staged
/// declarations can be release evidence, because a confirmed label exists
/// only where the user accepted the check, which biases it toward complete.
public struct VLMCheckRowV1: Codable, Sendable, Equatable {
    public static let kind = "vlm_check"
    public static let schemaVersion = 1

    public enum LabelKind: String, Codable, Sendable {
        /// The physical state was declared before capture.
        case staged
        /// The user confirmed the step after the check.
        case confirmed
    }

    public var kind = VLMCheckRowV1.kind
    public var schemaVersion = VLMCheckRowV1.schemaVersion
    public var provenance = "device"
    /// The check's trace id: one row per check call.
    public var fixtureID: String
    public var sessionID: UUID
    public var expectedVerdict: String
    /// An undecodable answer is no verdict: scored as uncertain, flagged.
    public var producedVerdict: String
    public var decodeFailed: Bool
    public var latencyMilliseconds: Int
    public var variantID: String
    public var checkTarget: String
    public var modelRevision: String
    public var deviceModel: String
    public var osBuild: String?
    public var labelKind: LabelKind
    public var authoredModelID: String
    /// Plan index of the checked step (the board's slot A).
    public var stepIndex: Int
    public var physicalCase: Bool?
    public var legalUseConfirmed: Bool?
    public var lightingCondition: String?
    public var occlusionCondition: String?

    enum CodingKeys: String, CodingKey {
        case kind
        case schemaVersion = "schema_version"
        case provenance
        case fixtureID = "fixture_id"
        case sessionID = "session_id"
        case expectedVerdict = "expected_verdict"
        case producedVerdict = "produced_verdict"
        case decodeFailed = "decode_failed"
        case latencyMilliseconds = "latency_ms"
        case variantID = "variant_id"
        case checkTarget = "check_target"
        case modelRevision = "model_revision"
        case deviceModel = "device_model"
        case osBuild = "os_build"
        case labelKind = "label_kind"
        case authoredModelID = "authored_model_id"
        case stepIndex = "step_index"
        case physicalCase = "physical_case"
        case legalUseConfirmed = "legal_use_confirmed"
        case lightingCondition = "lighting_condition"
        case occlusionCondition = "occlusion_condition"
    }

    /// One row per labeled check call in a finalized device session. An
    /// unlabeled session, or a check whose step has no expected count,
    /// writes nothing: a missing label is never guessed.
    public static func deviceRows(session: EvidenceSessionFile, traces: [EvidenceTraceRow]) -> [VLMCheckRowV1] {
        let truth = session.groundTruth
        let labelKind: LabelKind
        switch truth.kind {
        case .staged: labelKind = .staged
        case .confirmed: labelKind = .confirmed
        case .unlabeled: return []
        }
        return traces.compactMap { trace -> VLMCheckRowV1? in
            guard trace.pass == .check,
                  let stepIndex = trace.candidateStepIndices["A"],
                  let expected = ReplayAggregation.expectedCheckVerdict(
                      row: trace, expectedCompletedCount: truth.expectedCompletedCount
                  ) else { return nil }
            let decision = ReplayDecision(rawOutput: trace.rawOutput)
            return VLMCheckRowV1(
                fixtureID: trace.traceID.uuidString,
                sessionID: session.sessionID,
                expectedVerdict: expected,
                producedVerdict: decision?.result ?? "uncertain",
                decodeFailed: decision?.result == nil,
                latencyMilliseconds: trace.latencyMilliseconds,
                variantID: (trace.variant ?? .baseline).id,
                checkTarget: trace.checkTarget.rawValue,
                modelRevision: trace.modelRevision,
                deviceModel: session.deviceModel,
                osBuild: session.osBuild,
                labelKind: labelKind,
                authoredModelID: session.authoredModelID.uuidString,
                stepIndex: stepIndex,
                physicalCase: session.staged?.physicalCase,
                legalUseConfirmed: session.staged?.legalUseConfirmed,
                lightingCondition: session.staged?.lighting.rawValue,
                occlusionCondition: session.staged?.occlusion.rawValue
            )
        }
    }
}
