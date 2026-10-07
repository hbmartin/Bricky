import Foundation

/// One verification window's lattice evidence as a scorer row (kind
/// `lattice_window`, iOS 27 Phase 4). It is what the stud-keypoint entry
/// criterion is read from: how often the registration under a staged build
/// was ambiguous, how close its margins came to the lock threshold, and
/// whether a known build was called one stud off (or a shifted one
/// complete). Built from a bundle on a Mac by `bricky-harness lattice-rows`;
/// it never gates a release.
public struct LatticeWindowRowV1: Codable, Sendable, Equatable {
    public static let kind = "lattice_window"
    /// The lock rule's margin (`DepthICPTracker.Configuration`), and the
    /// band above it where a lock was granted but only just.
    public static let lockMargin: Float = 1.3
    public static let nearLockMargin: Float = 1.5

    public var kind = LatticeWindowRowV1.kind
    public var schemaVersion = 1
    /// `device` for windows recorded on a phone; `replay` or `synthetic`
    /// when the session itself says so. The entry readout counts device
    /// rows only.
    public var provenance: String
    /// The window id.
    public var fixtureID: String
    public var sessionID: String
    public var deviceModel: String
    public var stepIndex: Int
    public var trigger: String
    public var verdict: String
    public var offsetStuds: [Int]?
    public var uncertainReason: String?
    public var stagedScenario: String?
    public var expectedVerdict: String?
    public var frames: Int
    /// Frames where the lattice sweep ran and some alternative competed.
    public var sweptFrames: Int
    public var ambiguousFrames: Int
    public var lockedFrames: Int
    /// Locked frames whose margin sat in [1.3, 1.5).
    public var lockedNearThresholdFrames: Int
    /// The margins of the swept frames, oldest first.
    public var margins: [Float]
    /// How often each alternative set the margin.
    public var runnerUps: [String: Int]
    public var latticeContests: [LatticeContestRecord]?

    public init(
        provenance: String, fixtureID: String, sessionID: String, deviceModel: String, stepIndex: Int,
        trigger: String, verdict: String, offsetStuds: [Int]?, uncertainReason: String?, stagedScenario: String?,
        expectedVerdict: String?, frames: Int, sweptFrames: Int, ambiguousFrames: Int, lockedFrames: Int,
        lockedNearThresholdFrames: Int, margins: [Float], runnerUps: [String: Int],
        latticeContests: [LatticeContestRecord]?
    ) {
        self.provenance = provenance
        self.fixtureID = fixtureID
        self.sessionID = sessionID
        self.deviceModel = deviceModel
        self.stepIndex = stepIndex
        self.trigger = trigger
        self.verdict = verdict
        self.offsetStuds = offsetStuds
        self.uncertainReason = uncertainReason
        self.stagedScenario = stagedScenario
        self.expectedVerdict = expectedVerdict
        self.frames = frames
        self.sweptFrames = sweptFrames
        self.ambiguousFrames = ambiguousFrames
        self.lockedFrames = lockedFrames
        self.lockedNearThresholdFrames = lockedNearThresholdFrames
        self.margins = margins
        self.runnerUps = runnerUps
        self.latticeContests = latticeContests
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case schemaVersion = "schema_version"
        case provenance
        case fixtureID = "fixture_id"
        case sessionID = "session_id"
        case deviceModel = "device_model"
        case stepIndex = "step_index"
        case trigger
        case verdict
        case offsetStuds = "offset_studs"
        case uncertainReason = "uncertain_reason"
        case stagedScenario = "staged_scenario"
        case expectedVerdict = "expected_verdict"
        case frames
        case sweptFrames = "swept_frames"
        case ambiguousFrames = "ambiguous_frames"
        case lockedFrames = "locked_frames"
        case lockedNearThresholdFrames = "locked_near_threshold_frames"
        case margins
        case runnerUps = "runner_ups"
        case latticeContests = "lattice_contests"
    }

    /// One row per window, in the order given.
    public static func rows(
        windows: [VerificationWindowRecord], sessionID: UUID, deviceModel: String
    ) -> [LatticeWindowRowV1] {
        let provenance = deviceModel.hasPrefix("replay:") ? "replay"
            : deviceModel.hasPrefix("synthetic:") ? "synthetic" : "device"
        return windows.map { window in
            var margins: [Float] = []
            var runnerUps: [String: Int] = [:]
            var ambiguous = 0
            var locked = 0
            var nearThreshold = 0
            for frame in window.frames {
                // A margin of 0 records that no sweep ran; one at Float's
                // limit, that every alternative left the image.
                if frame.latticeMargin > 0, frame.latticeMargin < Float.greatestFiniteMagnitude {
                    margins.append(frame.latticeMargin)
                }
                if let runnerUp = frame.latticeRunnerUp { runnerUps[runnerUp, default: 0] += 1 }
                switch frame.registrationState {
                case "ambiguous":
                    ambiguous += 1
                case "locked":
                    locked += 1
                    if frame.latticeMargin < nearLockMargin { nearThreshold += 1 }
                default:
                    break
                }
            }
            return LatticeWindowRowV1(
                provenance: provenance,
                fixtureID: window.windowID.uuidString,
                sessionID: sessionID.uuidString,
                deviceModel: deviceModel,
                stepIndex: window.stepIndex,
                trigger: window.trigger.rawValue,
                verdict: window.verdict,
                offsetStuds: window.offsetStuds,
                uncertainReason: window.uncertainReason,
                stagedScenario: window.staged?.scenario.rawValue,
                expectedVerdict: window.staged?.expectedVerdict,
                frames: window.frames.count,
                sweptFrames: margins.count,
                ambiguousFrames: ambiguous,
                lockedFrames: locked,
                lockedNearThresholdFrames: nearThreshold,
                margins: margins,
                runnerUps: runnerUps,
                latticeContests: window.latticeContests
            )
        }
    }

    /// Every window of a loaded session.
    public static func rows(session: EvidenceBundleReader.Session) -> [LatticeWindowRowV1] {
        rows(
            windows: session.verificationWindows,
            sessionID: session.file.sessionID,
            deviceModel: session.file.deviceModel
        )
    }
}
