import Foundation

/// One repair-wording attempt (ADR 0017): the facts it was given, the String
/// Catalog template, what the language layer wrote, how the attempt ended,
/// and the line the user actually saw. Written to a session's
/// `wording.ndjson` with evidence capture on. These device pairs are what
/// the blinded preference test is run on, because a Mac is not the
/// phone's model tier.
public struct RepairWordingRecordV1: Codable, Sendable, Equatable {
    public static let filename = "wording.ndjson"
    public static let version = 1

    public var recordVersion = RepairWordingRecordV1.version
    public var recordID: UUID
    public var sessionID: UUID
    public var stepID: String
    public var action: String
    public var partLabel: String
    public var partCount: Int
    public var direction: String?
    public var studs: Int?
    public var turn: String?
    public var template: String
    /// What the model wrote, accepted or not; nil when it wrote nothing.
    public var modelSentence: String?
    /// `accepted`, `rejected_<reason>`, `unavailable_<reason>` or
    /// `failed_<reason>`.
    public var outcome: String
    /// The line on screen: the model's sentence when accepted, else the
    /// template.
    public var shown: String
    public var latencyMilliseconds: Int
    /// The system model is not pinned: the OS build identifies it.
    public var osBuild: String?
    public var deviceModel: String?
    public var createdAt: Date

    public init(
        recordID: UUID = UUID(), sessionID: UUID, stepID: String, action: String, partLabel: String, partCount: Int,
        direction: String?, studs: Int?, turn: String?, template: String, modelSentence: String?, outcome: String,
        shown: String, latencyMilliseconds: Int, osBuild: String?, deviceModel: String?, createdAt: Date
    ) {
        self.recordID = recordID
        self.sessionID = sessionID
        self.stepID = stepID
        self.action = action
        self.partLabel = partLabel
        self.partCount = partCount
        self.direction = direction
        self.studs = studs
        self.turn = turn
        self.template = template
        self.modelSentence = modelSentence
        self.outcome = outcome
        self.shown = shown
        self.latencyMilliseconds = latencyMilliseconds
        self.osBuild = osBuild
        self.deviceModel = deviceModel
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case recordVersion = "record_version"
        case recordID = "record_id"
        case sessionID = "session_id"
        case stepID = "step_id"
        case action
        case partLabel = "part_label"
        case partCount = "part_count"
        case direction, studs, turn, template
        case modelSentence = "model_sentence"
        case outcome, shown
        case latencyMilliseconds = "latency_ms"
        case osBuild = "os_build"
        case deviceModel = "device_model"
        case createdAt = "created_at"
    }
}
