import Foundation
import OSLog
import RecoveryMLX

/// Captures full-fidelity recovery evidence into `Evidence/<session>/` when
/// the developer toggle is on (ADR 0007). Everything is a copy: the recorder
/// never takes ownership of work files, so the existing deletion sites and
/// the startup orphan sweep stay untouched.
///
/// Recording must never break a recovery, so the write methods swallow their
/// errors after logging them; evidence is best-effort by design.
actor RecoveryEvidenceRecorder {
    struct RecordedCandidate: Sendable {
        let slot: String
        let stepIndex: Int
        let stepID: String
        let jpegData: Data?
    }

    static let directoryName = "Evidence"
    static let maxSessions = 40
    static let maxTotalBytes: Int64 = 2 * 1024 * 1024 * 1024

    nonisolated let sessionID: UUID

    private let root: URL
    let sessionDirectory: URL
    private(set) var session: EvidenceSessionFile
    private var started = false
    private var finalized = false
    private let logger = Logger(subsystem: AppConfig.bundleID, category: "Evidence")

    init(
        root: URL,
        instructionSHA256: String,
        authoredModelID: UUID,
        modelTitle: String,
        stepCount: Int,
        staged: StagedFixtureDeclaration?
    ) {
        let id = UUID()
        sessionID = id
        self.root = root
        sessionDirectory = root
            .appendingPathComponent(Self.directoryName, isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        session = EvidenceSessionFile(
            sessionVersion: EvidenceSchema.sessionVersion,
            sessionID: id,
            createdAt: .now,
            instructionSHA256: instructionSHA256,
            authoredModelID: authoredModelID,
            modelTitle: modelTitle,
            stepCount: stepCount,
            modelRevision: RecoveryModelManager.revision,
            deviceModel: DeviceIdentity.modelIdentifier,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            captures: [],
            staged: staged,
            groundTruth: staged.map {
                EvidenceGroundTruth(kind: .staged, expectedCompletedCount: $0.expectedCompletedCount)
            } ?? .unlabeled,
            estimate: nil,
            analysisError: nil
        )
    }

    func recordCaptures(_ captures: [RecoveryCapture]) {
        perform("record captures") {
            try ensureStarted()
            for capture in captures {
                let source = root.appendingPathComponent(capture.imageRelativePath)
                let destination = sessionDirectory
                    .appendingPathComponent("captures", isDirectory: true)
                    .appendingPathComponent("\(capture.id.uuidString).jpg")
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: source, to: destination)
            }
            session.captures = captures.map(EvidenceCaptureRecord.init)
            try writeSessionFile()
        }
    }

    /// Copies the board before the caller's `defer` deletes it, writes every
    /// tile, and appends the trace row.
    func recordPass(
        pass: RecoveryPassKind,
        passIndex: Int,
        capture: RecoveryCapture?,
        candidates: [RecordedCandidate],
        boardURL: URL,
        prompt: String,
        trace: MLXGenerationTrace
    ) {
        perform("record \(pass.rawValue) pass") {
            try ensureStarted()
            let traceID = UUID()
            let boardRelativePath = "boards/\(traceID.uuidString).jpg"
            try FileManager.default.copyItem(
                at: boardURL,
                to: sessionDirectory.appendingPathComponent(boardRelativePath)
            )
            var tilePaths: [String: String] = [:]
            let tileDirectory = sessionDirectory
                .appendingPathComponent("tiles", isDirectory: true)
                .appendingPathComponent(traceID.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: tileDirectory, withIntermediateDirectories: true)
            for candidate in candidates {
                guard let data = candidate.jpegData else { continue }
                let relative = "tiles/\(traceID.uuidString)/\(candidate.slot).jpg"
                try data.write(to: sessionDirectory.appendingPathComponent(relative), options: .atomic)
                tilePaths[candidate.slot] = relative
            }
            let row = EvidenceTraceRow(
                traceVersion: EvidenceSchema.traceVersion,
                traceID: traceID,
                sessionID: sessionID,
                pass: pass,
                passIndex: passIndex,
                captureID: capture?.id,
                captureAngle: capture?.angle.rawValue,
                boardRelativePath: boardRelativePath,
                tileRelativePaths: tilePaths,
                candidateStepIndices: Dictionary(uniqueKeysWithValues: candidates.map { ($0.slot, $0.stepIndex) }),
                candidateStepIDs: Dictionary(uniqueKeysWithValues: candidates.map { ($0.slot, $0.stepID) }),
                prompt: prompt,
                schemaJSON: trace.schemaJSON,
                maxTokens: trace.maxTokens,
                rawOutput: trace.rawOutput,
                decodeError: trace.decodeErrorDescription,
                termination: trace.termination.rawValue,
                generatedTokens: trace.generatedTokens,
                latencyMilliseconds: trace.latencyMilliseconds,
                memoryFootprintBytes: ProcessFootprint.currentBytes(),
                modelRevision: session.modelRevision,
                createdAt: .now
            )
            try appendTraceRow(row)
        }
    }

    /// Copies the depth observation a geometric recovery fit against.
    ///
    /// The only bundle input that cannot be reconstructed from anything else,
    /// so a corpus collected without it could never support a geometric A/B
    /// without re-capturing every physical fixture. Roughly 0.5 MB per
    /// session against a 2 GB cap.
    func recordDepthFrame(_ frame: RegistrationFrameInput, captureID: UUID) {
        perform("record depth frame") {
            try ensureStarted()
            let stem = "depth/\(captureID.uuidString)"
            try write(frame.depth, to: "\(stem).depth")
            try write(frame.confidence, to: "\(stem).confidence")
            var rawDepthPath: String?
            var rawConfidencePath: String?
            if let rawDepth = frame.rawDepth, let rawConfidence = frame.rawConfidence {
                rawDepthPath = "\(stem).raw-depth"
                rawConfidencePath = "\(stem).raw-confidence"
                try write(rawDepth, to: rawDepthPath!)
                try write(rawConfidence, to: rawConfidencePath!)
            }
            let record = EvidenceDepthFrameRecord(
                depthVersion: EvidenceSchema.depthVersion,
                captureID: captureID,
                width: frame.width,
                height: frame.height,
                depthIntrinsics: (0..<3).flatMap { column in
                    (0..<3).map { row in frame.depthIntrinsics[column][row] }
                },
                worldFromCamera: (0..<4).flatMap { row in
                    (0..<4).map { column in frame.worldFromCamera[column][row] }
                },
                timestamp: frame.timestamp,
                depthRelativePath: "\(stem).depth",
                confidenceRelativePath: "\(stem).confidence",
                rawDepthRelativePath: rawDepthPath,
                rawConfidenceRelativePath: rawConfidencePath
            )
            try EvidenceSchema.encoder(prettyPrinted: true).encode(record)
                .write(to: sessionDirectory.appendingPathComponent("\(stem).json"), options: .atomic)
        }
    }

    /// Depth sidecars written so far, decoded back from `depth/*.json`.
    func loadDepthFrames() -> [EvidenceDepthFrameRecord] {
        let directory = sessionDirectory.appendingPathComponent("depth", isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return [] }
        let decoder = EvidenceSchema.decoder()
        return contents
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(EvidenceDepthFrameRecord.self, from: data)
            }
    }

    /// Appends one geometric recovery attempt's candidate fits (ADR 0010).
    /// Written to `fits.ndjson`, not `traces.ndjson`: a fit is not an
    /// inference call, and an Evidence Trace means exactly one of those.
    func recordFits(_ records: [GeometricFitRecord]) {
        guard !records.isEmpty else { return }
        perform("record geometric fits") {
            try ensureStarted()
            let encoder = EvidenceSchema.encoder()
            var payload = Data()
            for record in records {
                payload.append(try encoder.encode(record))
                payload.append(UInt8(ascii: "\n"))
            }
            try append(payload, to: "fits.ndjson")
        }
    }

    /// Fit rows written so far, decoded back from `fits.ndjson`.
    func loadFitRecords() -> [GeometricFitRecord] {
        let fits = sessionDirectory.appendingPathComponent("fits.ndjson")
        guard let data = try? Data(contentsOf: fits) else { return [] }
        let decoder = EvidenceSchema.decoder()
        return data.split(separator: UInt8(ascii: "\n"))
            .compactMap { try? decoder.decode(GeometricFitRecord.self, from: Data($0)) }
    }

    func finalize(estimate: RecoveryEstimate?, analysisError: String?, groundTruth: EvidenceGroundTruth) {
        perform("finalize session") {
            try ensureStarted()
            guard !finalized else { return }
            finalized = true
            session.estimate = estimate.map(EvidenceSessionFile.EstimateSummary.init)
            session.analysisError = analysisError
            session.groundTruth = groundTruth
            try writeSessionFile()
        }
    }

    /// Trace rows written so far, decoded back from `traces.ndjson`.
    func loadTraceRows() -> [EvidenceTraceRow] {
        let traces = sessionDirectory.appendingPathComponent("traces.ndjson")
        guard let data = try? Data(contentsOf: traces) else { return [] }
        let decoder = EvidenceSchema.decoder()
        return data.split(separator: UInt8(ascii: "\n"))
            .compactMap { try? decoder.decode(EvidenceTraceRow.self, from: Data($0)) }
    }

    // MARK: - Internals

    func perform(_ label: String, _ work: () throws -> Void) {
        do {
            try work()
        } catch {
            logger.error("Evidence \(label, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func ensureStarted() throws {
        guard !started else { return }
        try Self.purgeIfNeeded(root: root, logger: logger)
        for subdirectory in ["captures", "boards", "tiles", "depth"] {
            try FileManager.default.createDirectory(
                at: sessionDirectory.appendingPathComponent(subdirectory, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        started = true
        try writeSessionFile()
    }

    private func writeSessionFile() throws {
        let data = try EvidenceSchema.encoder(prettyPrinted: true).encode(session)
        try data.write(to: sessionDirectory.appendingPathComponent("session.json"), options: .atomic)
    }

    private func appendTraceRow(_ row: EvidenceTraceRow) throws {
        var line = try EvidenceSchema.encoder().encode(row)
        line.append(UInt8(ascii: "\n"))
        try append(line, to: "traces.ndjson")
    }

    /// Writes a numeric plane as raw little-endian binary, row-major, so any
    /// reader can reshape it without a decoder.
    private func write<Element>(_ values: [Element], to relativePath: String) throws {
        try values.withUnsafeBufferPointer { buffer in
            try Data(buffer: buffer).write(
                to: sessionDirectory.appendingPathComponent(relativePath),
                options: .atomic
            )
        }
    }

    /// Appends already-encoded NDJSON bytes to a session file, creating it on
    /// first write.
    private func append(_ payload: Data, to filename: String) throws {
        let url = sessionDirectory.appendingPathComponent(filename)
        if !FileManager.default.fileExists(atPath: url.path) {
            try payload.write(to: url, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: payload)
    }

    /// Oldest-first purge keeping the store under the session and byte caps.
    /// Runs before a new session directory is created, so the caps bound what
    /// this session adds to, not what it writes.
    static func purgeIfNeeded(root: URL, logger: Logger? = nil) throws {
        let store = root.appendingPathComponent(directoryName, isDirectory: true)
        let fileManager = FileManager.default
        guard let sessions = try? fileManager.contentsOfDirectory(
            at: store,
            includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey]
        ) else { return }
        var dated: [(url: URL, created: Date, bytes: Int64)] = []
        for url in sessions {
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .isDirectoryKey])
            guard values?.isDirectory == true else { continue }
            dated.append((url, values?.creationDate ?? .distantPast, directorySize(url)))
        }
        dated.sort { $0.created < $1.created }
        var total = dated.reduce(Int64(0)) { $0 + $1.bytes }
        var count = dated.count
        for entry in dated {
            // The incoming session still needs a slot under both caps.
            guard count >= maxSessions || total > maxTotalBytes - 64 * 1024 * 1024 else { break }
            try fileManager.removeItem(at: entry.url)
            logger?.notice("Evidence purge removed session \(entry.url.lastPathComponent, privacy: .public)")
            total -= entry.bytes
            count -= 1
        }
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }
}
