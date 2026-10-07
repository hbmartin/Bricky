import Foundation

/// Writes a valid evidence bundle from in-memory images and labels, for
/// pipeline smoke tests only (ADR 0019). Its device model is
/// `synthetic:bricky-harness`, which every release path and the training
/// exporter refuse, and its traces record no device output: nothing in it
/// was ever seen by a phone or a model.
public enum SyntheticEvidenceBundle {
    public static let deviceModel = "synthetic:bricky-harness"
    /// What a trace records in place of a device's output and termination.
    public static let notRun = "not_run"

    public struct Trace: Sendable {
        public var pass: RecoveryPassKind
        /// The board the model would see, as JPEG.
        public var board: Data
        /// Slot letter → tile JPEG.
        public var tiles: [String: Data]
        public var candidateStepIndices: [String: Int]
        public var candidateStepIDs: [String: String]
        public var prompt: String
        public var schemaJSON: String
        public var maxTokens: Int

        public init(
            pass: RecoveryPassKind, board: Data, tiles: [String: Data], candidateStepIndices: [String: Int],
            candidateStepIDs: [String: String], prompt: String, schemaJSON: String, maxTokens: Int
        ) {
            self.pass = pass
            self.board = board
            self.tiles = tiles
            self.candidateStepIndices = candidateStepIndices
            self.candidateStepIDs = candidateStepIDs
            self.prompt = prompt
            self.schemaJSON = schemaJSON
            self.maxTokens = maxTokens
        }
    }

    public struct Session: Sendable {
        public var sessionID: UUID
        public var instructionSHA256: String
        public var authoredModelID: UUID
        public var modelTitle: String
        public var stepCount: Int
        public var physicalBuildID: String
        /// The staged truth: the last completed step, and its id.
        public var expectedCompletedCount: Int
        public var expectedStepID: String
        /// The "physical" photo, as JPEG.
        public var capture: Data
        public var traces: [Trace]

        public init(
            sessionID: UUID, instructionSHA256: String, authoredModelID: UUID, modelTitle: String, stepCount: Int,
            physicalBuildID: String, expectedCompletedCount: Int, expectedStepID: String, capture: Data, traces: [Trace]
        ) {
            self.sessionID = sessionID
            self.instructionSHA256 = instructionSHA256
            self.authoredModelID = authoredModelID
            self.modelTitle = modelTitle
            self.stepCount = stepCount
            self.physicalBuildID = physicalBuildID
            self.expectedCompletedCount = expectedCompletedCount
            self.expectedStepID = expectedStepID
            self.capture = capture
            self.traces = traces
        }
    }

    /// Writes `sessions` as a bundle at `directory`, which must not exist.
    /// Identifiers inside each session derive from its session id, so the
    /// same input writes the same bytes.
    public static func write(
        _ sessions: [Session], to directory: URL, modelID: String, modelRevision: String, createdAt: Date
    ) throws {
        let files = FileManager.default
        let encoder = EvidenceSchema.encoder(prettyPrinted: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: false)
        let manifest = EvidenceBundleManifest(
            bundleVersion: EvidenceSchema.bundleVersion, createdAt: createdAt, appVersion: "synthetic",
            deviceModel: deviceModel, operatingSystem: "synthetic", modelID: modelID, modelRevision: modelRevision,
            sessionIDs: sessions.map(\.sessionID)
        )
        try encoder.encode(manifest).write(to: directory.appendingPathComponent("evidence_bundle.json"))

        for session in sessions {
            let sessionDirectory = directory
                .appendingPathComponent("sessions", isDirectory: true)
                .appendingPathComponent(session.sessionID.uuidString, isDirectory: true)
            let captureID = derivedID(session.sessionID, 0xC0)
            try files.createDirectory(at: sessionDirectory.appendingPathComponent("captures"), withIntermediateDirectories: true)
            try files.createDirectory(at: sessionDirectory.appendingPathComponent("boards"), withIntermediateDirectories: true)
            try session.capture.write(to: sessionDirectory.appendingPathComponent("captures/\(captureID.uuidString).jpg"))

            var lines = Data()
            for (index, trace) in session.traces.enumerated() {
                let traceID = derivedID(session.sessionID, index + 1)
                let tileDirectory = "tiles/\(traceID.uuidString)"
                try files.createDirectory(at: sessionDirectory.appendingPathComponent(tileDirectory), withIntermediateDirectories: true)
                try trace.board.write(to: sessionDirectory.appendingPathComponent("boards/\(traceID.uuidString).jpg"))
                var tilePaths: [String: String] = [:]
                for (slot, tile) in trace.tiles {
                    tilePaths[slot] = "\(tileDirectory)/\(slot).jpg"
                    try tile.write(to: sessionDirectory.appendingPathComponent("\(tileDirectory)/\(slot).jpg"))
                }
                let row = EvidenceTraceRow(
                    traceVersion: EvidenceSchema.traceVersion, traceID: traceID, sessionID: session.sessionID,
                    pass: trace.pass, passIndex: index, captureID: captureID, captureAngle: "center",
                    boardRelativePath: "boards/\(traceID.uuidString).jpg", tileRelativePaths: tilePaths,
                    candidateStepIndices: trace.candidateStepIndices, candidateStepIDs: trace.candidateStepIDs,
                    prompt: trace.prompt, schemaJSON: trace.schemaJSON, maxTokens: trace.maxTokens,
                    rawOutput: "", decodeError: nil, termination: notRun, generatedTokens: nil,
                    latencyMilliseconds: 0, memoryFootprintBytes: nil, modelRevision: modelRevision, createdAt: createdAt
                )
                lines.append(try EvidenceSchema.encoder().encode(row))
                lines.append(UInt8(ascii: "\n"))
            }
            try lines.write(to: sessionDirectory.appendingPathComponent("traces.ndjson"))

            let file = EvidenceSessionFile(
                sessionVersion: EvidenceSchema.sessionVersion, sessionID: session.sessionID, createdAt: createdAt,
                instructionSHA256: session.instructionSHA256, authoredModelID: session.authoredModelID,
                modelTitle: session.modelTitle, stepCount: session.stepCount, modelRevision: modelRevision,
                deviceModel: deviceModel, operatingSystem: "synthetic", appVersion: "synthetic",
                captures: [EvidenceCaptureRecord(
                    captureID: captureID, imageRelativePath: "captures/\(captureID.uuidString).jpg",
                    cameraTransform: Array(repeating: 0, count: 16), cameraIntrinsics: Array(repeating: 0, count: 9),
                    cameraImageResolution: [0, 0], alignmentID: derivedID(session.sessionID, 0xA11),
                    angle: "center", capturedAt: createdAt
                )],
                staged: StagedFixtureDeclaration(
                    expectedCompletedCount: session.expectedCompletedCount, lighting: .bright, occlusion: .none,
                    physicalCase: true, legalUseConfirmed: true
                ),
                groundTruth: EvidenceGroundTruth(
                    kind: .staged, expectedCompletedCount: session.expectedCompletedCount,
                    expectedStepID: session.expectedStepID
                ),
                estimate: nil, analysisError: nil, physicalBuildID: session.physicalBuildID
            )
            try encoder.encode(file).write(to: sessionDirectory.appendingPathComponent("session.json"))
        }
    }

    /// A stable id derived from a session id and an ordinal, so a seeded
    /// generator writes the same bundle twice.
    static func derivedID(_ base: UUID, _ ordinal: Int) -> UUID {
        var bytes = base.uuid
        let value = UInt32(truncatingIfNeeded: ordinal)
        bytes.12 ^= UInt8(truncatingIfNeeded: value >> 24)
        bytes.13 ^= UInt8(truncatingIfNeeded: value >> 16)
        bytes.14 ^= UInt8(truncatingIfNeeded: value >> 8)
        bytes.15 ^= UInt8(truncatingIfNeeded: value)
        return UUID(uuid: bytes)
    }
}
