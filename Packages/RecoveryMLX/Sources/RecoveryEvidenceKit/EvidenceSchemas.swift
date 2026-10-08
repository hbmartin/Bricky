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
    public static let depthVersion = 1

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

/// Sidecar describing one retained LiDAR depth observation, written beside its
/// binary planes as `depth/<capture-id>.json`.
///
/// The depth frame is the only input to a geometric recovery that cannot be
/// reconstructed from anything else in a bundle: captures are JPEGs of the same
/// scene but at the wrong resolution and without metric depth, and the fit
/// records are outputs, not inputs. A corpus collected without it could never
/// support a geometric A/B without re-capturing every physical fixture — the
/// re-collection the bundle format exists to prevent.
///
/// Planes are raw little-endian binary, row-major, `width * height` elements,
/// so any reader can reshape them without a decoder:
///
///     numpy.fromfile(path, dtype=numpy.float32).reshape(height, width)
public struct EvidenceDepthFrameRecord: Codable, Sendable {
    public let depthVersion: Int
    public let captureID: UUID
    public let width: Int
    public let height: Int
    /// Column-major 3x3, already scaled to the depth grid, so projecting a
    /// world point yields depth pixels directly.
    public let depthIntrinsics: [Float]
    /// Row-major 4x4.
    public let worldFromCamera: [Float]
    public let timestamp: TimeInterval
    /// `float32` — ARKit's smoothed scene depth, the ICP tracking input.
    public let depthRelativePath: String
    /// `uint8` — `ARConfidenceLevel` raw values.
    public let confidenceRelativePath: String
    /// `float32` — unsmoothed depth, the verifier's per-frame evidence.
    /// Absent when the session provided no distinct raw buffer.
    public let rawDepthRelativePath: String?
    public let rawConfidenceRelativePath: String?
    /// `uint8` RGB, interleaved, the camera image box-filtered onto the depth
    /// grid. Recorded for verification windows only, while evidence is on.
    public let colourRelativePath: String?
    /// `uint8`, 1 where person segmentation marks an occluder. Recorded, not
    /// yet used by any verdict (ADR 0007 amendment 2).
    public let occluderMaskRelativePath: String?
    /// How `colour` was converted, e.g. `rgb8_bt709_full`.
    public let colourEncoding: String?
    /// Row-major 4x4, model to world: the manual alignment a geometric
    /// recovery started from. It is both the ICP initial pose and the
    /// reference the pose-sanity check measures drift against, so with the
    /// planes it is the estimator's whole input. Recovery depth frames only;
    /// absent on window frames and on sessions recorded before 2026-10-08,
    /// which therefore cannot replay geometric recovery. Not the capture
    /// record's `world_from_model`, which is column-major and is the locked
    /// registration pose.
    public let coarseWorldFromModel: [Float]?
    /// Window frames only, when evidence is on: how long the colour and
    /// occluder channels took to extract on device, in milliseconds.
    public let auxiliaryExtractMilliseconds: Double?
    /// The person-segmentation buffer the occluder mask was resampled from,
    /// as ARKit delivered it. Window frames only.
    public let segmentationWidth: Int?
    public let segmentationHeight: Int?
    public let segmentationBytesPerRow: Int?

    public init(
        depthVersion: Int, captureID: UUID, width: Int, height: Int,
        depthIntrinsics: [Float], worldFromCamera: [Float], timestamp: TimeInterval,
        depthRelativePath: String, confidenceRelativePath: String,
        rawDepthRelativePath: String?, rawConfidenceRelativePath: String?,
        colourRelativePath: String? = nil, occluderMaskRelativePath: String? = nil, colourEncoding: String? = nil,
        coarseWorldFromModel: [Float]? = nil, auxiliaryExtractMilliseconds: Double? = nil,
        segmentationWidth: Int? = nil, segmentationHeight: Int? = nil, segmentationBytesPerRow: Int? = nil
    ) {
        self.depthVersion = depthVersion
        self.captureID = captureID
        self.width = width
        self.height = height
        self.depthIntrinsics = depthIntrinsics
        self.worldFromCamera = worldFromCamera
        self.timestamp = timestamp
        self.depthRelativePath = depthRelativePath
        self.confidenceRelativePath = confidenceRelativePath
        self.rawDepthRelativePath = rawDepthRelativePath
        self.rawConfidenceRelativePath = rawConfidenceRelativePath
        self.colourRelativePath = colourRelativePath
        self.occluderMaskRelativePath = occluderMaskRelativePath
        self.colourEncoding = colourEncoding
        self.coarseWorldFromModel = coarseWorldFromModel
        self.auxiliaryExtractMilliseconds = auxiliaryExtractMilliseconds
        self.segmentationWidth = segmentationWidth
        self.segmentationHeight = segmentationHeight
        self.segmentationBytesPerRow = segmentationBytesPerRow
    }

    enum CodingKeys: String, CodingKey {
        case depthVersion = "depth_version"
        case captureID = "capture_id"
        case width
        case height
        case depthIntrinsics = "depth_intrinsics"
        case worldFromCamera = "world_from_camera"
        case timestamp
        case depthRelativePath = "depth_relative_path"
        case confidenceRelativePath = "confidence_relative_path"
        case rawDepthRelativePath = "raw_depth_relative_path"
        case rawConfidenceRelativePath = "raw_confidence_relative_path"
        case colourRelativePath = "colour_relative_path"
        case occluderMaskRelativePath = "occluder_mask_relative_path"
        case colourEncoding = "colour_encoding"
        case coarseWorldFromModel = "coarse_world_from_model"
        case auxiliaryExtractMilliseconds = "auxiliary_extract_ms"
        case segmentationWidth = "segmentation_width"
        case segmentationHeight = "segmentation_height"
        case segmentationBytesPerRow = "segmentation_bytes_per_row"
    }

    /// Bytes a plane must contain to reshape cleanly. A truncated blob decodes
    /// into silently wrong geometry, so the reader checks this rather than
    /// trusting the file exists. `nil` when the declared dimensions are
    /// non-positive or the product overflows — hostile metadata must surface
    /// as a validation issue, not a crash.
    public func expectedBytes(elementSize: Int) -> Int? {
        guard width > 0, height > 0, elementSize > 0 else { return nil }
        let (pixels, pixelsOverflow) = width.multipliedReportingOverflow(by: height)
        guard !pixelsOverflow else { return nil }
        let (bytes, bytesOverflow) = pixels.multipliedReportingOverflow(by: elementSize)
        guard !bytesOverflow else { return nil }
        return bytes
    }
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
    /// Which lattice alternative set `latticeMargin`; the same names as
    /// `VerificationWindowFrame.latticeRunnerUp`. Absent when no sweep ran.
    public var latticeRunnerUp: String?

    public init(
        fitVersion: Int, fitID: UUID, sessionID: UUID, passIndex: Int, candidateIndex: Int,
        stepID: String, score: Float, inlierFraction: Float, visibleFraction: Float,
        unexplainedFraction: Float, phantomFraction: Float, rmsResidual: Float,
        latticeMargin: Float, worldFromModel: [Float], disqualification: FitDisqualification,
        conclusive: Bool, createdAt: Date, latticeRunnerUp: String? = nil
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
        self.latticeRunnerUp = latticeRunnerUp
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
        case latticeRunnerUp = "lattice_runner_up"
    }

    /// Whether `other` is the same measurement: every field but the record's
    /// own identity (`fit_id`, `created_at`, `session_id`), with floats
    /// compared bit for bit. A replay is reproducible only if this holds for
    /// every fit.
    public func isSameFit(as other: GeometricFitRecord) -> Bool {
        guard fitVersion == other.fitVersion, passIndex == other.passIndex else { return false }
        guard candidateIndex == other.candidateIndex, stepID == other.stepID else { return false }
        guard score.bitPattern == other.score.bitPattern else { return false }
        guard inlierFraction.bitPattern == other.inlierFraction.bitPattern else { return false }
        guard visibleFraction.bitPattern == other.visibleFraction.bitPattern else { return false }
        guard unexplainedFraction.bitPattern == other.unexplainedFraction.bitPattern else { return false }
        guard phantomFraction.bitPattern == other.phantomFraction.bitPattern else { return false }
        guard rmsResidual.bitPattern == other.rmsResidual.bitPattern else { return false }
        guard latticeMargin.bitPattern == other.latticeMargin.bitPattern else { return false }
        guard worldFromModel.map(\.bitPattern) == other.worldFromModel.map(\.bitPattern) else { return false }
        guard disqualification == other.disqualification, conclusive == other.conclusive else { return false }
        return latticeRunnerUp == other.latticeRunnerUp
    }
}

extension Array where Element == GeometricFitRecord {
    /// Each fitted step once, in candidate-index (plan) order: a benchmark
    /// row's `scored_step_ids`.
    public var scoredStepIDs: [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for fit in sorted(by: { $0.candidateIndex < $1.candidateIndex }) where seen.insert(fit.stepID).inserted {
            ordered.append(fit.stepID)
        }
        return ordered
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
    /// The geometric pass produced the estimate and no VLM weights were
    /// loaded: a conclusive fit, or `insufficient` when no VLM was admitted
    /// to fall back to (ADR 0010 amendment).
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
    /// Which VLM-path variant produced the call (ADR 0010 amendment).
    public let variant: RecoveryInferenceVariant?
    /// Decode telemetry plus memory and thermal state around the call.
    public let inference: InferenceTelemetry?
    /// Device conditions when the call was recorded.
    public let conditions: DeviceConditions?
    /// The model's distribution at each small-legal-set decision.
    public let readouts: [DecisionReadout]?
    /// Probe-scored calls: the decision's option probabilities.
    public let probe: ProbeReadout?
    /// Step checks only: the same target rendered from the check target
    /// the call did not use (`CheckTarget` raw value → tile path), so a
    /// replay can A/B the target on identical photos.
    public let alternateTileRelativePaths: [String: String]?
    /// AR photo checks only: where the step's delta fell in the photo.
    public let checkGeometry: CheckGeometryRecord?

    public init(
        traceVersion: Int, traceID: UUID, sessionID: UUID, pass: RecoveryPassKind, passIndex: Int,
        captureID: UUID?, captureAngle: String?, boardRelativePath: String,
        tileRelativePaths: [String: String], candidateStepIndices: [String: Int],
        candidateStepIDs: [String: String], prompt: String, schemaJSON: String, maxTokens: Int,
        rawOutput: String, decodeError: String?, termination: String, generatedTokens: Int?,
        latencyMilliseconds: Int, memoryFootprintBytes: Int64?, modelRevision: String, createdAt: Date,
        variant: RecoveryInferenceVariant? = nil, inference: InferenceTelemetry? = nil,
        conditions: DeviceConditions? = nil, readouts: [DecisionReadout]? = nil, probe: ProbeReadout? = nil,
        alternateTileRelativePaths: [String: String]? = nil, checkGeometry: CheckGeometryRecord? = nil
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
        self.variant = variant
        self.inference = inference
        self.conditions = conditions
        self.readouts = readouts
        self.probe = probe
        self.alternateTileRelativePaths = alternateTileRelativePaths
        self.checkGeometry = checkGeometry
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
        case variant
        case inference
        case conditions
        case readouts
        case probe
        case alternateTileRelativePaths = "alternate_tile_relative_paths"
        case checkGeometry = "check_geometry"
    }

    /// The target this call's board was drawn from; rows written before the
    /// axis existed were all guide-camera checks.
    public var checkTarget: CheckTarget { variant?.checkTarget ?? .guideCamera }

    /// A step check's row as it would read had it been drawn from `target`:
    /// slot A's tile swapped for the recorded alternate. Nil when that
    /// target was never rendered for this call.
    public func retargeted(to target: CheckTarget) -> EvidenceTraceRow? {
        guard pass == .check else { return nil }
        guard target != checkTarget else { return self }
        guard let alternate = alternateTileRelativePaths?[target.rawValue] else { return nil }
        var tiles = tileRelativePaths
        tiles["A"] = alternate
        var retargetedVariant = variant ?? .baseline
        retargetedVariant.checkTarget = target
        return EvidenceTraceRow(
            traceVersion: traceVersion, traceID: traceID, sessionID: sessionID, pass: pass, passIndex: passIndex,
            captureID: captureID, captureAngle: captureAngle, boardRelativePath: boardRelativePath,
            tileRelativePaths: tiles, candidateStepIndices: candidateStepIndices, candidateStepIDs: candidateStepIDs,
            prompt: prompt, schemaJSON: schemaJSON, maxTokens: maxTokens, rawOutput: rawOutput,
            decodeError: decodeError, termination: termination, generatedTokens: generatedTokens,
            latencyMilliseconds: latencyMilliseconds, memoryFootprintBytes: memoryFootprintBytes,
            modelRevision: modelRevision, createdAt: createdAt, variant: retargetedVariant, inference: inference,
            conditions: conditions, readouts: readouts, probe: probe,
            alternateTileRelativePaths: [checkTarget.rawValue: tileRelativePaths["A"]].compactMapValues { $0 },
            // The photo and its geometry are the same whichever tile is used.
            checkGeometry: checkGeometry
        )
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
    /// The registered model pose the capture was taken under, when one was
    /// locked (AR photo checks): 16 floats, column-major, the same layout as
    /// `cameraTransform`. Verification window poses are row-major; this one
    /// is not.
    public let worldFromModel: [Float]?
    /// The live registration when the photo was taken (AR photo checks):
    /// its state, lattice margin and runner-up, so a label derived from
    /// `worldFromModel` can be refused when the pose was near a lattice
    /// alias. Absent for recovery captures and older sessions.
    public var registrationState: String?
    public var latticeMargin: Float?
    public var latticeRunnerUp: String?

    public init(
        captureID: UUID, imageRelativePath: String, cameraTransform: [Float],
        cameraIntrinsics: [Float], cameraImageResolution: [Float], alignmentID: UUID,
        angle: String, capturedAt: Date, worldFromModel: [Float]? = nil,
        registrationState: String? = nil, latticeMargin: Float? = nil, latticeRunnerUp: String? = nil
    ) {
        self.captureID = captureID
        self.imageRelativePath = imageRelativePath
        self.cameraTransform = cameraTransform
        self.cameraIntrinsics = cameraIntrinsics
        self.cameraImageResolution = cameraImageResolution
        self.alignmentID = alignmentID
        self.angle = angle
        self.capturedAt = capturedAt
        self.worldFromModel = worldFromModel
        self.registrationState = registrationState
        self.latticeMargin = latticeMargin
        self.latticeRunnerUp = latticeRunnerUp
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
        case worldFromModel = "world_from_model"
        case registrationState = "registration_state"
        case latticeMargin = "lattice_margin"
        case latticeRunnerUp = "lattice_runner_up"
    }
}

public extension EvidenceCaptureRecord {
    /// How far the camera's optical axis points below the horizon, in
    /// degrees: 0 looks level, 90 looks straight down. Measured from the
    /// column-major ARKit camera-to-world transform (gravity-aligned world,
    /// camera looking down −Z), so it is the viewing elevation the release
    /// corpus must vary — unlike the `left/center/right` label, which every
    /// full session repeats. Nil for a malformed transform.
    var elevationDegrees: Double? {
        guard cameraTransform.count == 16 else { return nil }
        // Forward is −column 2, so its downward component is +column2.y,
        // element 9 in column-major order.
        let downward = Double(cameraTransform[9])
        guard downward.isFinite else { return nil }
        return asin(min(1, max(-1, downward))) * 180 / .pi
    }
}

public extension Array where Element == EvidenceCaptureRecord {
    /// The viewing elevation a benchmark row reports: the center capture's,
    /// which every hierarchical pass but the finalists sees alone.
    var benchmarkElevationDegrees: Double? {
        (first(where: { $0.angle == "center" }) ?? first)?.elevationDegrees
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
    public var osBuild: String?
    public var gpuArchitecture: String?
    public var physicalMemoryBytes: UInt64?
    /// Admission as it stood for the model this session could use.
    public var admission: AdmissionSnapshot?
    /// Conditions when the session opened and when it was finalized.
    public var conditionsStart: DeviceConditions?
    public var conditionsEnd: DeviceConditions?
    /// The physical build the session photographed, as the person labelled
    /// it (a short slug, `[a-z0-9-]{1,32}`). Sessions sharing a label share
    /// a build. Training and test data are split by it as well as by
    /// authored model, so a fine-tuned model cannot learn one build instead
    /// of the task (ADR 0019). Absent when nothing was declared.
    public var physicalBuildID: String?
    /// The LDraw part pack the session's geometry came from, e.g. `2026-07`.
    /// A replay against a different pack renders different candidates.
    /// Absent on sessions recorded before 2026-10-08.
    public var partPackVersion: String?

    /// Whether `label` is a usable physical-build slug.
    public static func isValidPhysicalBuildID(_ label: String) -> Bool {
        (1...32).contains(label.count)
            && label.unicodeScalars.allSatisfy { scalar in
                ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "-"
            }
    }

    public init(
        sessionVersion: Int, sessionID: UUID, createdAt: Date, instructionSHA256: String,
        authoredModelID: UUID, modelTitle: String, stepCount: Int, modelRevision: String,
        deviceModel: String, operatingSystem: String, appVersion: String,
        captures: [EvidenceCaptureRecord], staged: StagedFixtureDeclaration?,
        groundTruth: EvidenceGroundTruth, estimate: EstimateSummary?, analysisError: String?,
        osBuild: String? = nil, gpuArchitecture: String? = nil, physicalMemoryBytes: UInt64? = nil,
        admission: AdmissionSnapshot? = nil, conditionsStart: DeviceConditions? = nil,
        conditionsEnd: DeviceConditions? = nil, physicalBuildID: String? = nil, partPackVersion: String? = nil
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
        self.osBuild = osBuild
        self.gpuArchitecture = gpuArchitecture
        self.physicalMemoryBytes = physicalMemoryBytes
        self.admission = admission
        self.conditionsStart = conditionsStart
        self.conditionsEnd = conditionsEnd
        self.physicalBuildID = physicalBuildID
        self.partPackVersion = partPackVersion
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
        case osBuild = "os_build"
        case gpuArchitecture = "gpu_architecture"
        case physicalMemoryBytes = "physical_memory_bytes"
        case admission
        case conditionsStart = "conditions_start"
        case conditionsEnd = "conditions_end"
        case physicalBuildID = "physical_build_id"
        case partPackVersion = "part_pack_version"
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
    public let osBuild: String?
    public let gpuArchitecture: String?

    public init(bundleVersion: Int, createdAt: Date, appVersion: String, deviceModel: String,
                operatingSystem: String, modelID: String, modelRevision: String, sessionIDs: [UUID],
                osBuild: String? = nil, gpuArchitecture: String? = nil) {
        self.bundleVersion = bundleVersion
        self.createdAt = createdAt
        self.appVersion = appVersion
        self.deviceModel = deviceModel
        self.operatingSystem = operatingSystem
        self.modelID = modelID
        self.modelRevision = modelRevision
        self.sessionIDs = sessionIDs
        self.osBuild = osBuild
        self.gpuArchitecture = gpuArchitecture
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
        case osBuild = "os_build"
        case gpuArchitecture = "gpu_architecture"
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
    /// The center capture's measured viewing elevation (see
    /// `EvidenceCaptureRecord.elevationDegrees`). Release corpora must span
    /// at least two elevation bands.
    public let captureElevationDegrees: Double?
    /// `RecoveryInferenceVariant.id` of the arm that produced the row.
    public let variantID: String?
    public let osBuild: String?
    public let gpuArchitecture: String?
    public let thermalStateStart: String?
    public let thermalStateEnd: String?
    public let secondsSinceARStart: Double?
    public let latencyBucket: LatencyBucket?
    /// VLM inference calls the estimate cost (0 for a concluded geometric pass).
    public let vlmCalls: Int?
    public let prefillMillisecondsTotal: Int?
    public let decodeMillisecondsTotal: Int?
    public let batteryState: String?
    public let lowPowerMode: Bool?
    /// What `latency_ms` measures: `estimate_wall_clock` on device; replay
    /// rows say which replayed calls they sum.
    public let latencyScope: String?
    /// The steps the geometric leg fitted, in plan order. A geometric row
    /// has no board slots, so without these the release preflight could not
    /// see that the estimate was asked to tell the expected step from its
    /// neighbour. Absent when no geometric fit ran.
    public let scoredStepIDs: [String]?

    public init(
        schemaVersion: Int, fixtureID: String, instructionSHA256: String, pyldraw3Version: String,
        partPackVersion: String, expectedStepID: String, candidateSlots: [String: String],
        boardRelativePaths: [String], cameraMetadata: [[String: Float]], expectedStepIndex: Int,
        rankedStepIDs: [String], certainty: RecoveryCertainty,
        estimatorMethod: RecoveryMethod, modelRevision: String?, deviceModel: String,
        operatingSystem: String, latencyMilliseconds: Int, memoryPeakBytes: Int64,
        topStepIndex: Int?, physicalCase: Bool?, authoredModelID: String?,
        legalUseConfirmed: Bool?, lightingCondition: String?, captureAngle: String?,
        occlusionCondition: String?, captureElevationDegrees: Double? = nil,
        variantID: String? = nil, osBuild: String? = nil, gpuArchitecture: String? = nil,
        thermalStateStart: String? = nil, thermalStateEnd: String? = nil, secondsSinceARStart: Double? = nil,
        latencyBucket: LatencyBucket? = nil, vlmCalls: Int? = nil, prefillMillisecondsTotal: Int? = nil,
        decodeMillisecondsTotal: Int? = nil, batteryState: String? = nil, lowPowerMode: Bool? = nil,
        latencyScope: String? = nil, scoredStepIDs: [String]? = nil
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
        self.captureElevationDegrees = captureElevationDegrees
        self.variantID = variantID
        self.osBuild = osBuild
        self.gpuArchitecture = gpuArchitecture
        self.thermalStateStart = thermalStateStart
        self.thermalStateEnd = thermalStateEnd
        self.secondsSinceARStart = secondsSinceARStart
        self.latencyBucket = latencyBucket
        self.vlmCalls = vlmCalls
        self.prefillMillisecondsTotal = prefillMillisecondsTotal
        self.decodeMillisecondsTotal = decodeMillisecondsTotal
        self.batteryState = batteryState
        self.lowPowerMode = lowPowerMode
        self.latencyScope = latencyScope
        self.scoredStepIDs = scoredStepIDs
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
        case captureElevationDegrees = "capture_elevation_degrees"
        case variantID = "variant_id"
        case osBuild = "os_build"
        case gpuArchitecture = "gpu_architecture"
        case thermalStateStart = "thermal_state_start"
        case thermalStateEnd = "thermal_state_end"
        case secondsSinceARStart = "seconds_since_ar_start"
        case latencyBucket = "latency_bucket"
        case vlmCalls = "vlm_calls"
        case prefillMillisecondsTotal = "prefill_ms_total"
        case decodeMillisecondsTotal = "decode_ms_total"
        case batteryState = "battery_state"
        case lowPowerMode = "low_power_mode"
        case latencyScope = "latency_scope"
        case scoredStepIDs = "scored_step_ids"
    }
}

public enum DeviceIdentity {
    /// Hardware identifier such as "iPhone18,1" or "Mac14,12" — distinct from
    /// marketing names. On macOS `uname` reports only the CPU ("arm64"), so
    /// the model comes from `hw.model`; replay rows used to read
    /// "replay:arm64" and could not say which Mac produced them.
    public static var modelIdentifier: String {
        #if os(macOS)
        if let model = sysctlString("hw.model") { return model }
        #endif
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
