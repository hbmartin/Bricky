import Foundation

/// What the step verifier saw around a moment that matters: the last frames
/// it ingested, with the registration each was judged under and the verdict
/// after it (ADR 0007 amendment 2). Written to `windows/<window-id>.json`;
/// each frame's planes live under `windows/frames/`, shared between windows
/// that overlap.
public struct VerificationWindowRecord: Codable, Sendable, Equatable {
    public static let version = 1

    public enum Trigger: String, Codable, CaseIterable, Sendable {
        /// The published verdict changed kind.
        case verdictChange = "verdict_change"
        /// The user confirmed the step.
        case confirm
        /// The step changed while the verdict was not complete: the user
        /// advanced past the verifier.
        case override
        /// The user left the step without confirming it.
        case stepExit = "step_exit"
    }

    public var windowVersion = VerificationWindowRecord.version
    public var windowID: UUID
    public var sessionID: UUID
    public var stepID: String
    /// Plan index of the step under verification.
    public var stepIndex: Int
    public var trigger: Trigger
    public var createdAt: Date
    /// Oldest first.
    public var frames: [VerificationWindowFrame]
    /// The published verification when the window closed.
    public var verdict: String
    public var offsetStuds: [Int]?
    public var uncertainReason: String?
    public var detectability: String
    public var deltaPixels: Int
    /// Frames the verifier had used since the step began, not just this
    /// window's: a replay of the window alone sees only `frames.count`.
    public var framesUsed: Int
    public var completeFraction: Float
    public var incompleteFraction: Float
    public var staged: StagedVerificationDeclaration?
    /// The colour term's reading when the window closed, when it ran
    /// (M3.2, ADR 0007 amendment 3). The verdict above already reflects its
    /// mode: unchanged in shadow, possibly blocked in block only.
    public var colourTerm: ColourTermRecord?

    public init(
        windowID: UUID, sessionID: UUID, stepID: String, stepIndex: Int, trigger: Trigger, createdAt: Date,
        frames: [VerificationWindowFrame], verdict: String, offsetStuds: [Int]?, uncertainReason: String?,
        detectability: String, deltaPixels: Int, framesUsed: Int, completeFraction: Float,
        incompleteFraction: Float, staged: StagedVerificationDeclaration?, colourTerm: ColourTermRecord? = nil
    ) {
        self.windowID = windowID
        self.sessionID = sessionID
        self.stepID = stepID
        self.stepIndex = stepIndex
        self.trigger = trigger
        self.createdAt = createdAt
        self.frames = frames
        self.verdict = verdict
        self.offsetStuds = offsetStuds
        self.uncertainReason = uncertainReason
        self.detectability = detectability
        self.deltaPixels = deltaPixels
        self.framesUsed = framesUsed
        self.completeFraction = completeFraction
        self.incompleteFraction = incompleteFraction
        self.staged = staged
        self.colourTerm = colourTerm
    }

    enum CodingKeys: String, CodingKey {
        case windowVersion = "window_version"
        case windowID = "window_id"
        case sessionID = "session_id"
        case stepID = "step_id"
        case stepIndex = "step_index"
        case trigger
        case createdAt = "created_at"
        case frames
        case verdict
        case offsetStuds = "offset_studs"
        case uncertainReason = "uncertain_reason"
        case detectability
        case deltaPixels = "delta_pixels"
        case framesUsed = "frames_used"
        case completeFraction = "complete_fraction"
        case incompleteFraction = "incomplete_fraction"
        case staged
        case colourTerm = "colour_term"
    }
}

/// The colour term's reading of a step (ADR 0008 amendment, Proposed): its
/// mode, overall status (`agrees`, `disagrees`, `inconclusive_<reason>`),
/// and the evidence per authored colour, distances in Oklab.
public struct ColourTermRecord: Codable, Sendable, Equatable {
    public struct Group: Codable, Sendable, Equatable {
        public var code: Int
        public var status: String
        public var pixels: Int
        public var frames: Int
        public var authoredDistance: Float?
        public var nearestCode: Int?
        public var nearestDistance: Float?
        public var beneathCode: Int?

        public init(
            code: Int, status: String, pixels: Int, frames: Int, authoredDistance: Float?, nearestCode: Int?,
            nearestDistance: Float?, beneathCode: Int?
        ) {
            self.code = code
            self.status = status
            self.pixels = pixels
            self.frames = frames
            self.authoredDistance = authoredDistance
            self.nearestCode = nearestCode
            self.nearestDistance = nearestDistance
            self.beneathCode = beneathCode
        }

        enum CodingKeys: String, CodingKey {
            case code, status, pixels, frames
            case authoredDistance = "authored_distance"
            case nearestCode = "nearest_code"
            case nearestDistance = "nearest_distance"
            case beneathCode = "beneath_code"
        }
    }

    public var mode: String
    public var status: String
    public var framesWithColour: Int
    public var framesCalibrated: Int
    public var groups: [Group]

    public init(mode: String, status: String, framesWithColour: Int, framesCalibrated: Int, groups: [Group]) {
        self.mode = mode
        self.status = status
        self.framesWithColour = framesWithColour
        self.framesCalibrated = framesCalibrated
        self.groups = groups
    }

    enum CodingKeys: String, CodingKey {
        case mode, status, groups
        case framesWithColour = "frames_with_colour"
        case framesCalibrated = "frames_calibrated"
    }
}

/// One ingested frame of a window: which planes, the registration it was
/// judged under, and what the verifier published after it.
public struct VerificationWindowFrame: Codable, Sendable, Equatable {
    /// Names `windows/frames/<frame-id>.json`, an `EvidenceDepthFrameRecord`.
    public var frameID: UUID
    public var registrationState: String
    /// Row-major 4x4, like `EvidenceDepthFrameRecord.worldFromCamera`.
    public var worldFromModel: [Float]
    public var rmsResidual: Float
    public var inlierFraction: Float
    public var latticeMargin: Float
    public var verdictAfter: String
    public var ingestMilliseconds: Int

    public init(
        frameID: UUID, registrationState: String, worldFromModel: [Float], rmsResidual: Float,
        inlierFraction: Float, latticeMargin: Float, verdictAfter: String, ingestMilliseconds: Int
    ) {
        self.frameID = frameID
        self.registrationState = registrationState
        self.worldFromModel = worldFromModel
        self.rmsResidual = rmsResidual
        self.inlierFraction = inlierFraction
        self.latticeMargin = latticeMargin
        self.verdictAfter = verdictAfter
        self.ingestMilliseconds = ingestMilliseconds
    }

    enum CodingKeys: String, CodingKey {
        case frameID = "frame_id"
        case registrationState = "registration_state"
        case worldFromModel = "world_from_model"
        case rmsResidual = "rms_residual"
        case inlierFraction = "inlier_fraction"
        case latticeMargin = "lattice_margin"
        case verdictAfter = "verdict_after"
        case ingestMilliseconds = "ingest_ms"
    }
}

/// A physical verification state declared before the user shows it to the
/// verifier, in corpus-collection mode: the ground truth a window carries.
public struct StagedVerificationDeclaration: Codable, Hashable, Sendable {
    public enum Scenario: String, Codable, CaseIterable, Sendable {
        case complete
        case missing
        case shiftedOneStud = "shifted_one_stud"
        case rotated
        case wrongColour = "wrong_colour"
        case plateOffset = "plate_offset"
        case handOccluding = "hand_occluding"
    }

    public var scenario: Scenario
    /// Free text from the user, e.g. "toward me", for shifted builds.
    public var shiftDirectionUser: String?
    public var lighting: StagedFixtureDeclaration.Lighting
    public var occlusion: StagedFixtureDeclaration.Occlusion
    public var physicalCase: Bool
    public var legalUseConfirmed: Bool

    public init(
        scenario: Scenario, shiftDirectionUser: String? = nil, lighting: StagedFixtureDeclaration.Lighting,
        occlusion: StagedFixtureDeclaration.Occlusion, physicalCase: Bool, legalUseConfirmed: Bool
    ) {
        self.scenario = scenario
        self.shiftDirectionUser = shiftDirectionUser
        self.lighting = lighting
        self.occlusion = occlusion
        self.physicalCase = physicalCase
        self.legalUseConfirmed = legalUseConfirmed
    }

    /// The verdict a correct verifier gives. A hand in view does not change
    /// the build, so it is still complete (abstaining is the safe miss).
    public var expectedVerdict: String {
        switch scenario {
        case .complete, .handOccluding: "complete"
        case .missing, .rotated, .wrongColour, .plateOffset: "incomplete"
        case .shiftedOneStud: "misplaced"
        }
    }

    /// Scenarios today's depth verifier cannot see: a colour swap is
    /// invisible to depth, and verification tests translations only. Their
    /// rows are challenge evidence, never release evidence.
    public var isExpectedFailure: Bool {
        scenario == .wrongColour || scenario == .rotated
    }

    /// Scenarios outside the verification taxonomy's release gates.
    public var challengeClass: String? {
        switch scenario {
        case .rotated, .wrongColour, .plateOffset: scenario.rawValue
        case .complete, .missing, .shiftedOneStud, .handOccluding: nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case scenario
        case shiftDirectionUser = "shift_direction_user"
        case lighting
        case occlusion
        case physicalCase = "physical_case"
        case legalUseConfirmed = "legal_use_confirmed"
    }
}

/// Raw planes of an `EvidenceDepthFrameRecord`, read and size-checked.
public struct EvidenceDepthPlanes: Sendable {
    public let depth: [Float]
    public let confidence: [UInt8]
    public let rawDepth: [Float]?
    public let rawConfidence: [UInt8]?
    /// RGB8, interleaved, on the depth grid.
    public let colour: [UInt8]?
    /// 1 where a person occludes the pixel, else 0.
    public let occluderMask: [UInt8]?

    public enum LoadError: Error, CustomStringConvertible {
        case badDimensions
        case truncated(String, expected: Int, actual: Int)

        public var description: String {
            switch self {
            case .badDimensions: "depth frame has invalid dimensions"
            case let .truncated(path, expected, actual): "\(path) has \(actual) bytes, expected \(expected)"
            }
        }
    }

    /// Reads every plane `record` names, relative to `directory`, refusing
    /// any whose size does not match the declared grid.
    public static func load(_ record: EvidenceDepthFrameRecord, in directory: URL) throws -> EvidenceDepthPlanes {
        func plane<Element>(_ path: String, _ type: Element.Type, perPixel: Int = 1) throws -> [Element] {
            guard let expected = record.expectedBytes(elementSize: MemoryLayout<Element>.size * perPixel) else {
                throw LoadError.badDimensions
            }
            let data = try Data(contentsOf: directory.appendingPathComponent(path))
            guard data.count == expected else { throw LoadError.truncated(path, expected: expected, actual: data.count) }
            return data.withUnsafeBytes { Array($0.bindMemory(to: Element.self)) }
        }
        return EvidenceDepthPlanes(
            depth: try plane(record.depthRelativePath, Float.self),
            confidence: try plane(record.confidenceRelativePath, UInt8.self),
            rawDepth: try record.rawDepthRelativePath.map { try plane($0, Float.self) },
            rawConfidence: try record.rawConfidenceRelativePath.map { try plane($0, UInt8.self) },
            colour: try record.colourRelativePath.map { try plane($0, UInt8.self, perPixel: 3) },
            occluderMask: try record.occluderMaskRelativePath.map { try plane($0, UInt8.self) }
        )
    }
}

/// A `verification` row from real frames: written on device when a staged
/// verification declaration closes, and by SyntheticRGBD `--replay-bundle`
/// for each window it replays. Synthetic rows use the tool's own encoder.
public struct VerificationRowV1: Codable, Sendable, Equatable {
    public var kind = "verification"
    public var schemaVersion = 1
    /// `device` or `replay`.
    public var provenance: String
    /// The evidence window's id.
    public var fixtureID: String
    public var expectedVerdict: String
    public var producedVerdict: String
    public var detectability: String
    public var latencyMilliseconds: Int
    /// What `latency_ms` measures.
    public var latencyScope: String
    public var deviceModel: String
    public var authoredModelID: String
    public var stepIndex: Int
    public var deltaPixels: Int
    public var framesUsed: Int
    public var windowTrigger: String
    public var scenario: String?
    public var physicalCase: Bool?
    public var legalUseConfirmed: Bool?
    public var lightingCondition: String?
    public var occlusionCondition: String?
    /// Present only on scenarios outside the release taxonomy; the release
    /// preflight refuses any row that carries it.
    public var challengeClass: String?
    public var expectedFailure: Bool?
    /// Replay only: the verdict the device published, and whether the
    /// replay reproduced it from the window's frames alone.
    public var deviceVerdict: String?
    public var matchesDevice: Bool?

    public init(
        provenance: String, fixtureID: String, expectedVerdict: String, producedVerdict: String,
        detectability: String, latencyMilliseconds: Int, latencyScope: String, deviceModel: String,
        authoredModelID: String, stepIndex: Int, deltaPixels: Int, framesUsed: Int, windowTrigger: String,
        staged: StagedVerificationDeclaration?, deviceVerdict: String? = nil, matchesDevice: Bool? = nil
    ) {
        self.provenance = provenance
        self.fixtureID = fixtureID
        self.expectedVerdict = expectedVerdict
        self.producedVerdict = producedVerdict
        self.detectability = detectability
        self.latencyMilliseconds = latencyMilliseconds
        self.latencyScope = latencyScope
        self.deviceModel = deviceModel
        self.authoredModelID = authoredModelID
        self.stepIndex = stepIndex
        self.deltaPixels = deltaPixels
        self.framesUsed = framesUsed
        self.windowTrigger = windowTrigger
        scenario = staged?.scenario.rawValue
        physicalCase = staged?.physicalCase
        legalUseConfirmed = staged?.legalUseConfirmed
        lightingCondition = staged?.lighting.rawValue
        occlusionCondition = staged?.occlusion.rawValue
        challengeClass = staged?.challengeClass
        expectedFailure = staged?.isExpectedFailure == true ? true : nil
        self.deviceVerdict = deviceVerdict
        self.matchesDevice = matchesDevice
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case schemaVersion = "schema_version"
        case provenance
        case fixtureID = "fixture_id"
        case expectedVerdict = "expected_verdict"
        case producedVerdict = "produced_verdict"
        case detectability
        case latencyMilliseconds = "latency_ms"
        case latencyScope = "latency_scope"
        case deviceModel = "device_model"
        case authoredModelID = "authored_model_id"
        case stepIndex = "step_index"
        case deltaPixels = "delta_pixels"
        case framesUsed = "frames_used"
        case windowTrigger = "window_trigger"
        case scenario
        case physicalCase = "physical_case"
        case legalUseConfirmed = "legal_use_confirmed"
        case lightingCondition = "lighting_condition"
        case occlusionCondition = "occlusion_condition"
        case challengeClass = "challenge_class"
        case expectedFailure = "expected_failure"
        case deviceVerdict = "device_verdict"
        case matchesDevice = "matches_device"
    }
}

/// What the shadow build diff (M2.3) concluded when a window closed, one row
/// per window in `diffs.ndjson`. Plain fields only: the kit does not know
/// the app's domain types.
public struct BuildDiffRecord: Codable, Sendable, Equatable {
    public struct Placement: Codable, Sendable, Equatable {
        /// Index into the plan's placement timeline.
        public var placement: Int
        public var state: String
        /// `[dx, dz, dy, quarter_turns]` for displaced or rotated states.
        public var offset: [Int]?
        public var support: Int
        public var absence: Int
        public var unexplained: Int
        public var framesSeen: Int
        /// The colour term's status for the placement (`agrees`,
        /// `disagrees`, `inconclusive_<reason>`), when it ran (M3.2).
        public var colourStatus: String?
        /// The other model colour it looked like, and how far the observed
        /// colour was from the authored one, in Oklab.
        public var colourNearestCode: Int?
        public var colourAuthoredDistance: Float?

        public init(
            placement: Int, state: String, offset: [Int]?, support: Int, absence: Int, unexplained: Int, framesSeen: Int,
            colourStatus: String? = nil, colourNearestCode: Int? = nil, colourAuthoredDistance: Float? = nil
        ) {
            self.placement = placement
            self.state = state
            self.offset = offset
            self.support = support
            self.absence = absence
            self.unexplained = unexplained
            self.framesSeen = framesSeen
            self.colourStatus = colourStatus
            self.colourNearestCode = colourNearestCode
            self.colourAuthoredDistance = colourAuthoredDistance
        }

        enum CodingKeys: String, CodingKey {
            case placement, state, offset, support, absence, unexplained
            case framesSeen = "frames_seen"
            case colourStatus = "colour_status"
            case colourNearestCode = "colour_nearest_code"
            case colourAuthoredDistance = "colour_authored_distance"
        }
    }

    public var windowID: UUID
    public var stepID: String
    public var placements: [Placement]
    /// The placement-aware adapter's verdict, logged only.
    public var adapterVerdict: String
    /// What the user was shown.
    public var verifierVerdict: String
    public var framesUsed: Int

    public init(windowID: UUID, stepID: String, placements: [Placement], adapterVerdict: String, verifierVerdict: String, framesUsed: Int) {
        self.windowID = windowID
        self.stepID = stepID
        self.placements = placements
        self.adapterVerdict = adapterVerdict
        self.verifierVerdict = verifierVerdict
        self.framesUsed = framesUsed
    }

    enum CodingKeys: String, CodingKey {
        case windowID = "window_id"
        case stepID = "step_id"
        case placements
        case adapterVerdict = "adapter_verdict"
        case verifierVerdict = "verifier_verdict"
        case framesUsed = "frames_used"
    }
}
