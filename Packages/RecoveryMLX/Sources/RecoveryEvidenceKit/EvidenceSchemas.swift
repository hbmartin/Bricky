import Foundation

/// Version stamps for the evidence formats. The session directory layout is
/// also the export interchange format (ADR 0007), so every file carries an
/// explicit version and every type spells out snake_case coding keys —
/// Python tooling reads these files without Swift. This target is shared by
/// the iOS app and the `bricky-harness` macOS CLI so there is exactly one
/// definition of the contract.
public enum EvidenceSchema {
    public static let traceVersion = 1
    public static let sessionVersion = 1
    public static let bundleVersion = 1
    public static let fitVersion = 1

    public static func encoder(prettyPrinted: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Which stage of the hierarchical estimate an inference call served.
///
/// VLM passes only. A geometric candidate fit is not an inference call and is
/// recorded as a `GeometricFitRecord`, so that "Evidence Trace" keeps meaning
/// exactly one thing.
public enum RecoveryPassKind: String, Codable, Sendable {
    case broad
    case narrowing
    case narrow
    case finalist
    case check
}

/// Why a candidate fit was ruled out before its score could count.
///
/// The geometric estimator clamps a disqualified candidate's score to a
/// sentinel, which makes "left the build plane" indistinguishable from
/// "genuinely scored badly". Recording the reason separately keeps the
/// distinction that the score alone destroys.
public enum FitDisqualification: String, Codable, Sendable {
    case none
    /// The fit sank or climbed off the build plane — on an empty table,
    /// 4-DoF ICP will happily drop a candidate's top face onto the tabletop.
    case verticalDeviation = "vertical_deviation"
    /// The fit slid further horizontally than a user's coarse placement can
    /// explain, so it matched some other surface.
    case horizontalDeviation = "horizontal_deviation"
}

/// One scored candidate from a geometric recovery attempt (ADR 0010). Rows are
/// appended to a session's `fits.ndjson`.
///
/// Geometric recovery became the primary path but left no evidence, so a
/// bundle could only ever explain the VLM fallback. These rows answer the
/// geometric analogue of the estimator questions the trace rows answer: which
/// candidates were considered, what each scored, and — when the truth lost —
/// which term beat it.
public struct GeometricFitRecord: Codable, Sendable {
    public let fitVersion: Int
    public let fitID: UUID
    public let sessionID: UUID
    /// Which coarse-to-fine refinement pass scored this candidate.
    public let passIndex: Int
    /// Position in `plan.steps`; -1 is step zero. See the step-numbering
    /// section of EVIDENCE_BUNDLE_FORMAT.md.
    public let candidateIndex: Int
    public let stepID: String
    /// Two-sided coverage score. Comparable only within one attempt.
    public let score: Float
    public let inlierFraction: Float
    public let visibleFraction: Float
    /// Observed depth in front of the candidate surface: structure the
    /// candidate cannot explain.
    public let unexplainedFraction: Float
    /// Candidate surface with nothing observed at it: geometry the candidate
    /// predicts that is not there.
    public let phantomFraction: Float
    public let rmsResidual: Float
    public let latticeMargin: Float
    /// Row-major 4x4 solved pose, model to world.
    public let worldFromModel: [Float]
    public let disqualification: FitDisqualification
    /// True on the candidate the attempt concluded with; all false when the
    /// attempt was inconclusive and fell through to the VLM.
    public let conclusive: Bool
    public let createdAt: Date

    public init(
        fitVersion: Int, fitID: UUID, sessionID: UUID, passIndex: Int, candidateIndex: Int,
        stepID: String, score: Float, inlierFraction: Float, visibleFraction: Float,
        unexplainedFraction: Float, phantomFraction: Float, rmsResidual: Float,
        latticeMargin: Float, worldFromModel: [Float], disqualification: FitDisqualification,
        conclusive: Bool, createdAt: Date
    ) {
        self.fitVersion = fitVersion
        self.fitID = fitID
        self.sessionID = sessionID
        self.passIndex = passIndex
        self.candidateIndex = candidateIndex
        self.stepID = stepID
        self.score = score
        self.inlierFraction = inlierFraction
        self.visibleFraction = visibleFraction
        self.unexplainedFraction = unexplainedFraction
        self.phantomFraction = phantomFraction
        self.rmsResidual = rmsResidual
        self.latticeMargin = latticeMargin
        self.worldFromModel = worldFromModel
        self.disqualification = disqualification
        self.conclusive = conclusive
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case fitVersion = "fit_version"
        case fitID = "fit_id"
        case sessionID = "session_id"
        case passIndex = "pass_index"
        case candidateIndex = "candidate_index"
        case stepID = "step_id"
        case score
        case inlierFraction = "inlier_fraction"
        case visibleFraction = "visible_fraction"
        case unexplainedFraction = "unexplained_fraction"
        case phantomFraction = "phantom_fraction"
        case rmsResidual = "rms_residual"
        case latticeMargin = "lattice_margin"
        case worldFromModel = "world_from_model"
        case disqualification
        case conclusive
        case createdAt = "created_at"
    }
}

/// Advisory certainty of a recovery estimate, shared by the app's domain and
/// benchmark rows.
public enum RecoveryCertainty: String, Codable, Hashable, Sendable {
    case high
    case medium
    case low
    case insufficient
}

/// Which pipeline produced a recovery estimate (ADR 0010). Lives here, beside
/// `RecoveryBenchmarkV1`, so the scorer contract has exactly one Swift
/// definition — the same reason `RecoveryCertainty` moved out of the app
/// domain.
///
/// The three cases are distinguished because they are budgeted differently:
/// a geometric conclusion pays only for the fit, whereas a fallback pays for
/// the fit *and* the inference it did not avoid. Collapsing the last two would
/// make the composite latency gate unmeasurable.
public enum RecoveryMethod: String, Codable, Hashable, Sendable {
    /// The geometric pass concluded; no VLM weights were loaded.
    case geometric
    /// The geometric pass ran, stepped aside, and the VLM estimator concluded.
    /// Latency covers both legs.
    case composite
    /// No geometric pass was possible (no depth observation), so the VLM
    /// estimator ran alone.
    case vlm
}

/// One inference call's full record. Rows are appended to a session's
/// `traces.ndjson` and reference sibling image files by relative path.
public struct EvidenceTraceRow: Codable, Sendable {
    public let traceVersion: Int
    public let traceID: UUID
    public let sessionID: UUID
    public let pass: RecoveryPassKind
    public let passIndex: Int
    public let captureID: UUID?
    public let captureAngle: String?
    public let boardRelativePath: String
    /// slot letter → tile image path relative to the session directory.
    public let tileRelativePaths: [String: String]
    /// slot letter → candidate step index (-1 is step zero / not started).
    public let candidateStepIndices: [String: Int]
    /// slot letter → authored step identifier.
    public let candidateStepIDs: [String: String]
    public let prompt: String
    public let schemaJSON: String
    public let maxTokens: Int
    public let rawOutput: String
    public let decodeError: String?
    public let termination: String
    public let generatedTokens: Int?
    public let latencyMilliseconds: Int
    public let memoryFootprintBytes: Int64?
    public let modelRevision: String
    public let createdAt: Date

    public init(
        traceVersion: Int, traceID: UUID, sessionID: UUID, pass: RecoveryPassKind, passIndex: Int,
        captureID: UUID?, captureAngle: String?, boardRelativePath: String,
        tileRelativePaths: [String: String], candidateStepIndices: [String: Int],
        candidateStepIDs: [String: String], prompt: String, schemaJSON: String, maxTokens: Int,
        rawOutput: String, decodeError: String?, termination: String, generatedTokens: Int?,
        latencyMilliseconds: Int, memoryFootprintBytes: Int64?, modelRevision: String, createdAt: Date
    ) {
        self.traceVersion = traceVersion
        self.traceID = traceID
        self.sessionID = sessionID
        self.pass = pass
        self.passIndex = passIndex
        self.captureID = captureID
        self.captureAngle = captureAngle
        self.boardRelativePath = boardRelativePath
        self.tileRelativePaths = tileRelativePaths
        self.candidateStepIndices = candidateStepIndices
        self.candidateStepIDs = candidateStepIDs
        self.prompt = prompt
        self.schemaJSON = schemaJSON
        self.maxTokens = maxTokens
        self.rawOutput = rawOutput
        self.decodeError = decodeError
        self.termination = termination
        self.generatedTokens = generatedTokens
        self.latencyMilliseconds = latencyMilliseconds
        self.memoryFootprintBytes = memoryFootprintBytes
        self.modelRevision = modelRevision
        self.createdAt = createdAt
    }

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

/// Snake_case record of one AR capture so the interchange format stays
/// stable independent of the app's domain types.
public struct EvidenceCaptureRecord: Codable, Sendable {
    public let captureID: UUID
    public let imageRelativePath: String
    public let cameraTransform: [Float]
    public let cameraIntrinsics: [Float]
    public let cameraImageResolution: [Float]
    public let alignmentID: UUID
    public let angle: String
    public let capturedAt: Date

    public init(
        captureID: UUID, imageRelativePath: String, cameraTransform: [Float],
        cameraIntrinsics: [Float], cameraImageResolution: [Float], alignmentID: UUID,
        angle: String, capturedAt: Date
    ) {
        self.captureID = captureID
        self.imageRelativePath = imageRelativePath
        self.cameraTransform = cameraTransform
        self.cameraIntrinsics = cameraIntrinsics
        self.cameraImageResolution = cameraImageResolution
        self.alignmentID = alignmentID
        self.angle = angle
        self.capturedAt = capturedAt
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
public struct StagedFixtureDeclaration: Codable, Hashable, Sendable {
    public enum Lighting: String, Codable, CaseIterable, Sendable {
        case bright, dim, mixed
    }

    public enum Occlusion: String, Codable, CaseIterable, Sendable {
        case none, partial, heavy
    }

    /// Completed-count semantics: 0 means not started (step zero).
    public var expectedCompletedCount: Int
    public var lighting: Lighting
    public var occlusion: Occlusion
    public var physicalCase: Bool
    public var legalUseConfirmed: Bool

    public init(expectedCompletedCount: Int, lighting: Lighting, occlusion: Occlusion,
                physicalCase: Bool, legalUseConfirmed: Bool) {
        self.expectedCompletedCount = expectedCompletedCount
        self.lighting = lighting
        self.occlusion = occlusion
        self.physicalCase = physicalCase
        self.legalUseConfirmed = legalUseConfirmed
    }

    enum CodingKeys: String, CodingKey {
        case expectedCompletedCount = "expected_completed_count"
        case lighting
        case occlusion
        case physicalCase = "physical_case"
        case legalUseConfirmed = "legal_use_confirmed"
    }
}

public struct EvidenceGroundTruth: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Labeled by the user confirming a step after a real recovery.
        case confirmed
        /// Declared before capture in corpus-collection mode.
        case staged
        /// No label; failures and abandoned sessions stay unlabeled on purpose.
        case unlabeled
    }

    public var kind: Kind
    /// Completed-count semantics: 0 means not started (step zero).
    public var expectedCompletedCount: Int?
    public var expectedStepID: String?
    /// What the user actually confirmed — on staged sessions this is a
    /// cross-check against the declaration, not the label.
    public var confirmedCompletedCount: Int?
    public var confirmedAt: Date?

    public static let unlabeled = EvidenceGroundTruth(kind: .unlabeled)

    public init(kind: Kind, expectedCompletedCount: Int? = nil, expectedStepID: String? = nil,
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
public struct EvidenceSessionFile: Codable, Sendable {
    public struct EstimateSummary: Codable, Sendable {
        public let rankedStepIDs: [String]
        public let certainty: String
        public let insufficiencyCause: String?
        public let latencyMilliseconds: Int
        /// Which pipeline produced this estimate. Optional so sessions written
        /// before the field existed still decode; the session header's
        /// `model_revision` records only which VLM was loadable and must never
        /// be read as the method.
        public let method: RecoveryMethod?
        /// Revision of whatever produced the estimate — the pinned VLM for
        /// `.vlm`/`.composite`, the solver revision for `.geometric`.
        public let modelRevision: String?

        public init(rankedStepIDs: [String], certainty: String, insufficiencyCause: String?,
                    latencyMilliseconds: Int, method: RecoveryMethod? = nil,
                    modelRevision: String? = nil) {
            self.rankedStepIDs = rankedStepIDs
            self.certainty = certainty
            self.insufficiencyCause = insufficiencyCause
            self.latencyMilliseconds = latencyMilliseconds
            self.method = method
            self.modelRevision = modelRevision
        }

        enum CodingKeys: String, CodingKey {
            case rankedStepIDs = "ranked_step_ids"
            case certainty
            case insufficiencyCause = "insufficiency_cause"
            case latencyMilliseconds = "latency_ms"
            case method
            case modelRevision = "model_revision"
        }
    }

    public let sessionVersion: Int
    public let sessionID: UUID
    public let createdAt: Date
    public let instructionSHA256: String
    public let authoredModelID: UUID
    public let modelTitle: String
    public let stepCount: Int
    public let modelRevision: String
    public let deviceModel: String
    public let operatingSystem: String
    public let appVersion: String
    public var captures: [EvidenceCaptureRecord]
    public var staged: StagedFixtureDeclaration?
    public var groundTruth: EvidenceGroundTruth
    public var estimate: EstimateSummary?
    public var analysisError: String?

    public init(
        sessionVersion: Int, sessionID: UUID, createdAt: Date, instructionSHA256: String,
        authoredModelID: UUID, modelTitle: String, stepCount: Int, modelRevision: String,
        deviceModel: String, operatingSystem: String, appVersion: String,
        captures: [EvidenceCaptureRecord], staged: StagedFixtureDeclaration?,
        groundTruth: EvidenceGroundTruth, estimate: EstimateSummary?, analysisError: String?
    ) {
        self.sessionVersion = sessionVersion
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.instructionSHA256 = instructionSHA256
        self.authoredModelID = authoredModelID
        self.modelTitle = modelTitle
        self.stepCount = stepCount
        self.modelRevision = modelRevision
        self.deviceModel = deviceModel
        self.operatingSystem = operatingSystem
        self.appVersion = appVersion
        self.captures = captures
        self.staged = staged
        self.groundTruth = groundTruth
        self.estimate = estimate
        self.analysisError = analysisError
    }

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

/// Root `evidence_bundle.json` of an exported bundle.
public struct EvidenceBundleManifest: Codable, Sendable {
    public let bundleVersion: Int
    public let createdAt: Date
    public let appVersion: String
    public let deviceModel: String
    public let operatingSystem: String
    public let modelID: String
    public let modelRevision: String
    public let sessionIDs: [UUID]

    public init(bundleVersion: Int, createdAt: Date, appVersion: String, deviceModel: String,
                operatingSystem: String, modelID: String, modelRevision: String, sessionIDs: [UUID]) {
        self.bundleVersion = bundleVersion
        self.createdAt = createdAt
        self.appVersion = appVersion
        self.deviceModel = deviceModel
        self.operatingSystem = operatingSystem
        self.modelID = modelID
        self.modelRevision = modelRevision
        self.sessionIDs = sessionIDs
    }

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

/// The device-benchmark row consumed by `Tools/RecoveryEvaluation/score_results.py`.
public struct RecoveryBenchmarkV1: Codable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let fixtureID: String
    public let instructionSHA256: String
    public let pyldraw3Version: String
    public let partPackVersion: String
    public let expectedStepID: String
    public let candidateSlots: [String: String]
    public let boardRelativePaths: [String]
    public let cameraMetadata: [[String: Float]]
    public let expectedStepIndex: Int
    public let rankedStepIDs: [String]
    public let certainty: RecoveryCertainty
    /// Which pipeline produced the estimate. Required: the scorer buckets
    /// latency on it, and a row that cannot say how it was produced cannot be
    /// scored against the right gate.
    public let estimatorMethod: RecoveryMethod
    /// Weights or solver revision. Informational only — never parsed to infer
    /// the method (that mistake made the geometric bucket unreachable).
    public let modelRevision: String?
    public let deviceModel: String
    public let operatingSystem: String
    /// Wall clock for the whole recovery, including a geometric leg that
    /// stepped aside. See `estimatorMethod`.
    public let latencyMilliseconds: Int
    public let memoryPeakBytes: Int64
    public let topStepIndex: Int?
    public let physicalCase: Bool?
    public let authoredModelID: String?
    public let legalUseConfirmed: Bool?
    public let lightingCondition: String?
    public let captureAngle: String?
    public let occlusionCondition: String?

    public init(
        schemaVersion: Int, fixtureID: String, instructionSHA256: String, pyldraw3Version: String,
        partPackVersion: String, expectedStepID: String, candidateSlots: [String: String],
        boardRelativePaths: [String], cameraMetadata: [[String: Float]], expectedStepIndex: Int,
        rankedStepIDs: [String], certainty: RecoveryCertainty,
        estimatorMethod: RecoveryMethod, modelRevision: String?, deviceModel: String,
        operatingSystem: String, latencyMilliseconds: Int, memoryPeakBytes: Int64,
        topStepIndex: Int?, physicalCase: Bool?, authoredModelID: String?,
        legalUseConfirmed: Bool?, lightingCondition: String?, captureAngle: String?,
        occlusionCondition: String?
    ) {
        self.schemaVersion = schemaVersion
        self.fixtureID = fixtureID
        self.instructionSHA256 = instructionSHA256
        self.pyldraw3Version = pyldraw3Version
        self.partPackVersion = partPackVersion
        self.expectedStepID = expectedStepID
        self.candidateSlots = candidateSlots
        self.boardRelativePaths = boardRelativePaths
        self.cameraMetadata = cameraMetadata
        self.expectedStepIndex = expectedStepIndex
        self.rankedStepIDs = rankedStepIDs
        self.certainty = certainty
        self.estimatorMethod = estimatorMethod
        self.modelRevision = modelRevision
        self.deviceModel = deviceModel
        self.operatingSystem = operatingSystem
        self.latencyMilliseconds = latencyMilliseconds
        self.memoryPeakBytes = memoryPeakBytes
        self.topStepIndex = topStepIndex
        self.physicalCase = physicalCase
        self.authoredModelID = authoredModelID
        self.legalUseConfirmed = legalUseConfirmed
        self.lightingCondition = lightingCondition
        self.captureAngle = captureAngle
        self.occlusionCondition = occlusionCondition
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case fixtureID = "fixture_id"
        case instructionSHA256 = "instruction_sha256"
        case pyldraw3Version = "pyldraw3_version"
        case partPackVersion = "part_pack_version"
        case expectedStepID = "expected_step_id"
        case candidateSlots = "candidate_slots"
        case boardRelativePaths = "board_relative_paths"
        case cameraMetadata = "camera_metadata"
        case expectedStepIndex = "expected_step_index"
        case rankedStepIDs = "ranked_step_ids"
        case certainty
        case estimatorMethod = "estimator_method"
        case modelRevision = "model_revision"
        case deviceModel = "device_model"
        case operatingSystem = "operating_system"
        case latencyMilliseconds = "latency_ms"
        case memoryPeakBytes = "memory_peak_bytes"
        case topStepIndex = "top_step_index"
        case physicalCase = "physical_case"
        case authoredModelID = "authored_model_id"
        case legalUseConfirmed = "legal_use_confirmed"
        case lightingCondition = "lighting_condition"
        case captureAngle = "capture_angle"
        case occlusionCondition = "occlusion_condition"
    }
}

public enum DeviceIdentity {
    /// Hardware identifier such as "iPhone17,1" or "Mac16,6" — distinct from
    /// marketing names.
    public static var modelIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}

public enum ProcessFootprint {
    /// The process's `phys_footprint` — the number jetsam actually judges,
    /// unlike MLX's allocator statistics.
    public static func currentBytes() -> Int64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int64(info.phys_footprint)
    }
}
