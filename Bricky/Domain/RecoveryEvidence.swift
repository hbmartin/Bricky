import Foundation
import RecoveryMLX

/// Version stamps for the on-device evidence formats. The session directory
/// layout is also the export interchange format (ADR 0007), so every file
/// carries an explicit version and every type spells out snake_case coding
/// keys — Python tooling reads these files without Swift.
enum EvidenceSchema {
    static let traceVersion = 1
    static let sessionVersion = 1
    static let bundleVersion = 1

    static func encoder(prettyPrinted: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Which stage of the hierarchical estimate an inference call served.
enum RecoveryPassKind: String, Codable, Sendable {
    case broad
    case narrowing
    case narrow
    case finalist
    case check
}

/// One inference call's full record. Rows are appended to a session's
/// `traces.ndjson` and reference sibling image files by relative path.
struct EvidenceTraceRow: Codable, Sendable {
    let traceVersion: Int
    let traceID: UUID
    let sessionID: UUID
    let pass: RecoveryPassKind
    let passIndex: Int
    let captureID: UUID?
    let captureAngle: String?
    let boardRelativePath: String
    /// slot letter → tile image path relative to the session directory.
    let tileRelativePaths: [String: String]
    /// slot letter → candidate step index (-1 is step zero / not started).
    let candidateStepIndices: [String: Int]
    /// slot letter → authored step identifier.
    let candidateStepIDs: [String: String]
    let prompt: String
    let schemaJSON: String
    let maxTokens: Int
    let rawOutput: String
    let decodeError: String?
    let termination: String
    let generatedTokens: Int?
    let latencyMilliseconds: Int
    let memoryFootprintBytes: Int64?
    let modelRevision: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case traceVersion = "trace_version"
        case traceID = "trace_id"
        case sessionID = "session_id"
        case pass
        case passIndex = "pass_index"
        case captureID = "capture_id"
        case captureAngle = "capture_angle"
        case boardRelativePath = "board_relative_path"
        case tileRelativePaths = "tile_relative_paths"
        case candidateStepIndices = "candidate_step_indices"
        case candidateStepIDs = "candidate_step_ids"
        case prompt
        case schemaJSON = "schema_json"
        case maxTokens = "max_tokens"
        case rawOutput = "raw_output"
        case decodeError = "decode_error"
        case termination
        case generatedTokens = "generated_tokens"
        case latencyMilliseconds = "latency_ms"
        case memoryFootprintBytes = "memory_footprint_bytes"
        case modelRevision = "model_revision"
        case createdAt = "created_at"
    }
}

/// Snake_case mirror of `RecoveryCapture` so the interchange format stays
/// stable even if the domain type evolves.
struct EvidenceCaptureRecord: Codable, Sendable {
    let captureID: UUID
    let imageRelativePath: String
    let cameraTransform: [Float]
    let cameraIntrinsics: [Float]
    let cameraImageResolution: [Float]
    let alignmentID: UUID
    let angle: String
    let capturedAt: Date

    init(_ capture: RecoveryCapture) {
        captureID = capture.id
        imageRelativePath = "captures/\(capture.id.uuidString).jpg"
        cameraTransform = capture.cameraTransform
        cameraIntrinsics = capture.cameraIntrinsics
        cameraImageResolution = capture.cameraImageResolution
        alignmentID = capture.alignmentID
        angle = capture.angle.rawValue
        capturedAt = capture.capturedAt
    }

    enum CodingKeys: String, CodingKey {
        case captureID = "capture_id"
        case imageRelativePath = "image_relative_path"
        case cameraTransform = "camera_transform"
        case cameraIntrinsics = "camera_intrinsics"
        case cameraImageResolution = "camera_image_resolution"
        case alignmentID = "alignment_id"
        case angle
        case capturedAt = "captured_at"
    }
}

/// Conditions declared up front in corpus-collection mode, matching the
/// release-corpus fields of `RecoveryBenchmarkV1`.
struct StagedFixtureDeclaration: Codable, Hashable, Sendable {
    enum Lighting: String, Codable, CaseIterable, Sendable {
        case bright, dim, mixed
    }

    enum Occlusion: String, Codable, CaseIterable, Sendable {
        case none, partial, heavy
    }

    /// Completed-count semantics: 0 means not started (step zero).
    var expectedCompletedCount: Int
    var lighting: Lighting
    var occlusion: Occlusion
    var physicalCase: Bool
    var legalUseConfirmed: Bool

    enum CodingKeys: String, CodingKey {
        case expectedCompletedCount = "expected_completed_count"
        case lighting
        case occlusion
        case physicalCase = "physical_case"
        case legalUseConfirmed = "legal_use_confirmed"
    }
}

struct EvidenceGroundTruth: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// Labeled by the user confirming a step after a real recovery.
        case confirmed
        /// Declared before capture in corpus-collection mode.
        case staged
        /// No label; failures and abandoned sessions stay unlabeled on purpose.
        case unlabeled
    }

    var kind: Kind
    /// Completed-count semantics: 0 means not started (step zero).
    var expectedCompletedCount: Int?
    var expectedStepID: String?
    /// What the user actually confirmed — on staged sessions this is a
    /// cross-check against the declaration, not the label.
    var confirmedCompletedCount: Int?
    var confirmedAt: Date?

    static let unlabeled = EvidenceGroundTruth(kind: .unlabeled)

    init(kind: Kind, expectedCompletedCount: Int? = nil, expectedStepID: String? = nil,
         confirmedCompletedCount: Int? = nil, confirmedAt: Date? = nil) {
        self.kind = kind
        self.expectedCompletedCount = expectedCompletedCount
        self.expectedStepID = expectedStepID
        self.confirmedCompletedCount = confirmedCompletedCount
        self.confirmedAt = confirmedAt
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case expectedCompletedCount = "expected_completed_count"
        case expectedStepID = "expected_step_id"
        case confirmedCompletedCount = "confirmed_completed_count"
        case confirmedAt = "confirmed_at"
    }
}

/// A session's `session.json`: everything about one recovery run that is not
/// per-inference-call.
struct EvidenceSessionFile: Codable, Sendable {
    struct EstimateSummary: Codable, Sendable {
        let rankedStepIDs: [String]
        let certainty: String
        let insufficiencyCause: String?
        let latencyMilliseconds: Int

        init(_ estimate: RecoveryEstimate) {
            rankedStepIDs = estimate.rankedStepIDs
            certainty = estimate.certainty.rawValue
            insufficiencyCause = estimate.insufficiencyCause?.rawValue
            latencyMilliseconds = estimate.latencyMilliseconds
        }

        enum CodingKeys: String, CodingKey {
            case rankedStepIDs = "ranked_step_ids"
            case certainty
            case insufficiencyCause = "insufficiency_cause"
            case latencyMilliseconds = "latency_ms"
        }
    }

    let sessionVersion: Int
    let sessionID: UUID
    let createdAt: Date
    let instructionSHA256: String
    let authoredModelID: UUID
    let modelTitle: String
    let stepCount: Int
    let modelRevision: String
    let deviceModel: String
    let operatingSystem: String
    let appVersion: String
    var captures: [EvidenceCaptureRecord]
    var staged: StagedFixtureDeclaration?
    var groundTruth: EvidenceGroundTruth
    var estimate: EstimateSummary?
    var analysisError: String?

    enum CodingKeys: String, CodingKey {
        case sessionVersion = "session_version"
        case sessionID = "session_id"
        case createdAt = "created_at"
        case instructionSHA256 = "instruction_sha256"
        case authoredModelID = "authored_model_id"
        case modelTitle = "model_title"
        case stepCount = "step_count"
        case modelRevision = "model_revision"
        case deviceModel = "device_model"
        case operatingSystem = "operating_system"
        case appVersion = "app_version"
        case captures
        case staged
        case groundTruth = "ground_truth"
        case estimate
        case analysisError = "analysis_error"
    }
}

/// Root `evidence_bundle.json` of an exported bundle. The zip's directory
/// layout — this manifest plus `sessions/<uuid>/` copied verbatim — is the
/// interchange format `bricky-harness` and Python tooling consume.
struct EvidenceBundleManifest: Codable, Sendable {
    let bundleVersion: Int
    let createdAt: Date
    let appVersion: String
    let deviceModel: String
    let operatingSystem: String
    let modelID: String
    let modelRevision: String
    let sessionIDs: [UUID]

    enum CodingKeys: String, CodingKey {
        case bundleVersion = "bundle_version"
        case createdAt = "created_at"
        case appVersion = "app_version"
        case deviceModel = "device_model"
        case operatingSystem = "operating_system"
        case modelID = "model_id"
        case modelRevision = "model_revision"
        case sessionIDs = "session_ids"
    }
}

enum DeviceIdentity {
    /// Hardware identifier such as "iPhone17,1" — distinct from
    /// `UIDevice.model`, which only says "iPhone".
    static var modelIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}
