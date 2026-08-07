import ArgumentParser
import CoreGraphics
import Foundation
import RecoveryEvidenceKit
import RecoveryMLX

@main
struct BrickyHarness: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bricky-harness",
        abstract: "Replay Bricky evidence bundles through the exact device inference runtime.",
        discussion: """
        Weights: hf download mlx-community/Qwen3-VL-4B-Instruct-4bit \\
                   --revision 2fd8dacbdb8f1e54b8c005f081ec5bf79c56376b --local-dir <model-dir>

        Replay is a Mac-vs-Mac A/B instrument: greedy guided decoding is
        deterministic per platform, but iOS and macOS Metal kernels can flip
        near-tie argmax, so compare replays against replays, not against the
        device rows. Score results with:
        uv run python Tools/RecoveryEvaluation/score_results.py <out> --allow-small-corpus
        """,
        subcommands: [Replay.self, Recompose.self]
    )
}

struct Replay: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Replay a bundle's rank traces and emit RecoveryBenchmarkV1 NDJSON."
    )

    @Option(help: "Path to an unzipped evidence bundle directory.")
    var bundle: String

    @Option(name: .customLong("model-dir"), help: "Directory containing the pinned model revision.")
    var modelDirectory: String?

    @Option(help: "Output NDJSON path for benchmark rows; per-trace results land beside it as <out>.traces.ndjson.")
    var out: String?

    @Option(name: .customLong("prompt-file"), help: "Replace every recorded rank prompt with this file's contents (A/B).")
    var promptFile: String?

    @Option(name: .customLong("max-tokens"), help: "Override rank maxTokens (A/B).")
    var maxTokens: Int?

    @Flag(help: "Recompose boards from captures + tiles instead of replaying the stored board images.")
    var recompose = false

    @Flag(name: .customLong("all-passes"), help: "Replay every rank trace, not only the finalist passes.")
    var allPasses = false

    @Flag(name: .customLong("dry-run"), help: "Validate bundle structure and exit without loading weights.")
    var dryRun = false

    mutating func run() async throws {
        let reader = try EvidenceBundleReader(bundleDirectory: URL(fileURLWithPath: bundle))
        let issues = reader.validate()
        guard issues.isEmpty else {
            for issue in issues { FileHandle.standardError.write(Data("invalid bundle: \(issue)\n".utf8)) }
            throw ExitCode(1)
        }
        let sessions = try reader.loadSessions()
        print("bundle ok: \(sessions.count) sessions, \(sessions.reduce(0) { $0 + $1.traceRows.count }) traces, device \(reader.manifest.deviceModel), model \(reader.manifest.modelRevision.prefix(12))…")
        if dryRun { return }
        guard let modelDirectory, let out else {
            throw ValidationError("--model-dir and --out are required unless --dry-run is set.")
        }
        let promptOverride = try promptFile.map { try String(contentsOfFile: $0, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) }
        let modelURL = URL(fileURLWithPath: modelDirectory)
        let runtime = MLXRecoveryRuntime()
        let encoder = EvidenceSchema.encoder()
        var benchmarkLines: [Data] = []
        var traceLines: [Data] = []

        for session in sessions {
            let rankRows = session.traceRows
                .filter { $0.pass != .check }
                .filter { allPasses || $0.pass == .finalist }
            var finalistReplays: [(row: EvidenceTraceRow, output: MLXRankOutput?)] = []
            var replayLatency = 0
            for row in rankRows {
                let board = try boardURL(for: row, in: session)
                let response = try await runtime.rankWithTrace(
                    imageURL: board,
                    prompt: promptOverride ?? row.prompt,
                    candidateCount: row.candidateStepIDs.count,
                    modelDirectory: modelURL,
                    maxTokens: maxTokens
                )
                if row.pass == .finalist {
                    finalistReplays.append((row, response.output))
                    replayLatency += response.trace.latencyMilliseconds
                }
                traceLines.append(try encoder.encode(ReplayTraceResult(row: row, response: response,
                                                                       promptOverridden: promptOverride != nil,
                                                                       recomposed: recompose)))
                print("replayed \(row.pass.rawValue) \(row.traceID.uuidString.prefix(8)) → \(response.trace.termination.rawValue), \(response.trace.latencyMilliseconds) ms")
            }
            if let rowData = try benchmarkRow(session: session, finalistReplays: finalistReplays, replayLatency: replayLatency) {
                benchmarkLines.append(rowData)
            } else {
                print("session \(session.file.sessionID.uuidString.prefix(8)) is unlabeled — no benchmark row")
            }
        }

        try write(lines: benchmarkLines, to: URL(fileURLWithPath: out))
        try write(lines: traceLines, to: URL(fileURLWithPath: out + ".traces.ndjson"))
        print("wrote \(benchmarkLines.count) benchmark rows to \(out)")
    }

    private func boardURL(for row: EvidenceTraceRow, in session: EvidenceBundleReader.Session) throws -> URL {
        guard recompose else {
            return session.directory.appendingPathComponent(row.boardRelativePath)
        }
        let recomposed = try BoardRecomposer.recompose(row: row, in: session)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bricky-harness-\(row.traceID.uuidString).jpg")
        try RecoveryBoardLayoutV1.writeJPEG(recomposed, to: url)
        return url
    }

    /// Mirrors the estimator's Borda scoring and cross-view certainty so
    /// replayed finalist passes aggregate exactly like the device does.
    private func benchmarkRow(
        session: EvidenceBundleReader.Session,
        finalistReplays: [(row: EvidenceTraceRow, output: MLXRankOutput?)],
        replayLatency: Int
    ) throws -> Data? {
        let truth = session.file.groundTruth
        guard truth.kind != .unlabeled,
              let expectedCount = truth.expectedCompletedCount,
              let expectedStepID = truth.expectedStepID,
              !finalistReplays.isEmpty else { return nil }
        let slotSource = finalistReplays.first(where: { $0.row.captureAngle == "center" })?.row
            ?? finalistReplays[0].row
        let finalists = slotSource.candidateStepIDs.values.sorted {
            (Self.stepNumber(from: $0) ?? 0) < (Self.stepNumber(from: $1) ?? 0)
        }
        var rankings: [[(position: Int, stepID: String)]] = []
        for (row, output) in finalistReplays {
            guard let output, output.status == "matched" else { continue }
            let mapped = output.ranking.enumerated().compactMap { position, slot in
                row.candidateStepIDs[slot].map { (position: position, stepID: $0) }
            }
            guard !mapped.isEmpty else { continue }
            rankings.append(mapped)
        }
        var ranked: [String] = []
        var certainty = RecoveryCertainty.insufficient
        if rankings.count >= 2 {
            var scores: [String: Int] = [:]
            for ranking in rankings {
                for entry in ranking {
                    scores[entry.stepID, default: 0] += max(0, finalists.count - entry.position)
                }
            }
            ranked = Array(finalists.sorted {
                let lhs = scores[$0, default: 0], rhs = scores[$1, default: 0]
                if lhs == rhs {
                    return (Self.stepNumber(from: $0) ?? 0) < (Self.stepNumber(from: $1) ?? 0)
                }
                return lhs > rhs
            }.prefix(3))
            let leaders = rankings.compactMap { $0.first?.stepID }
            let agreement = Dictionary(grouping: leaders, by: { $0 }).values.map(\.count).max() ?? 0
            certainty = agreement >= 3 ? .high : (agreement == 2 ? .medium : .low)
        }
        let row = RecoveryBenchmarkV1(
            schemaVersion: RecoveryBenchmarkV1.schemaVersion,
            fixtureID: session.file.sessionID.uuidString,
            instructionSHA256: session.file.instructionSHA256,
            pyldraw3Version: "1.5.0",
            partPackVersion: "2026-07",
            expectedStepID: expectedStepID,
            candidateSlots: slotSource.candidateStepIDs,
            boardRelativePaths: finalistReplays.map(\.row.boardRelativePath),
            cameraMetadata: session.file.captures.map { capture in
                var metadata: [String: Float] = [:]
                if capture.cameraIntrinsics.count >= 9 {
                    metadata["fx"] = capture.cameraIntrinsics[0]
                    metadata["fy"] = capture.cameraIntrinsics[4]
                    metadata["cx"] = capture.cameraIntrinsics[6]
                    metadata["cy"] = capture.cameraIntrinsics[7]
                }
                return metadata
            },
            expectedStepIndex: expectedCount,
            rankedStepIDs: ranked,
            certainty: certainty,
            // Replay reconstructs the estimate from recorded VLM rank traces
            // alone, so a replayed row is `.vlm` by construction regardless of
            // what produced the original estimate on device.
            estimatorMethod: .vlm,
            modelRevision: session.file.modelRevision,
            // Replay rows must never enter a release corpus as device rows.
            deviceModel: "replay:\(DeviceIdentity.modelIdentifier)",
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            latencyMilliseconds: replayLatency,
            memoryPeakBytes: ProcessFootprint.currentBytes() ?? 0,
            topStepIndex: ranked.first.flatMap(Self.stepNumber(from:)),
            physicalCase: session.file.staged?.physicalCase,
            authoredModelID: session.file.authoredModelID.uuidString,
            legalUseConfirmed: session.file.staged?.legalUseConfirmed,
            lightingCondition: session.file.staged?.lighting.rawValue,
            captureAngle: session.file.captures.map(\.angle).joined(separator: ","),
            occlusionCondition: session.file.staged?.occlusion.rawValue
        )
        return try EvidenceSchema.encoder().encode(row)
    }

    /// Step IDs are "<rootSection>#<number>"; the number is the authored step
    /// index with 0 meaning step zero.
    static func stepNumber(from stepID: String) -> Int? {
        stepID.split(separator: "#").last.flatMap { Int($0) }
    }

    private func write(lines: [Data], to url: URL) throws {
        var data = Data()
        for line in lines {
            data.append(line)
            data.append(UInt8(ascii: "\n"))
        }
        try data.write(to: url, options: .atomic)
    }
}

struct Recompose: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Rebuild one trace's board from its capture and tiles (layout debugging)."
    )

    @Option(help: "Path to an unzipped evidence bundle directory.")
    var bundle: String

    @Option(help: "Trace UUID to recompose.")
    var trace: String

    @Option(help: "Output JPEG path.")
    var out: String

    mutating func run() async throws {
        let reader = try EvidenceBundleReader(bundleDirectory: URL(fileURLWithPath: bundle))
        for session in try reader.loadSessions() {
            if let row = session.traceRows.first(where: { $0.traceID.uuidString.lowercased() == trace.lowercased() }) {
                let image = try BoardRecomposer.recompose(row: row, in: session)
                try RecoveryBoardLayoutV1.writeJPEG(image, to: URL(fileURLWithPath: out))
                print("recomposed \(row.pass.rawValue) board → \(out)")
                return
            }
        }
        throw ValidationError("trace \(trace) not found in bundle")
    }
}

enum BoardRecomposer {
    static func recompose(row: EvidenceTraceRow, in session: EvidenceBundleReader.Session) throws -> CGImage {
        guard let captureID = row.captureID else {
            throw ValidationError("trace \(row.traceID) has no capture reference")
        }
        let physical = try RecoveryBoardLayoutV1.loadImage(
            at: session.directory.appendingPathComponent("captures/\(captureID.uuidString).jpg")
        )
        let candidates = try row.tileRelativePaths.sorted(by: { $0.key < $1.key }).map { slot, tilePath in
            RecoveryBoardLayoutV1.Candidate(
                slot: slot,
                image: try RecoveryBoardLayoutV1.loadImage(at: session.directory.appendingPathComponent(tilePath)),
                stepNumber: (row.candidateStepIndices[slot] ?? -1) + 1
            )
        }
        return try RecoveryBoardLayoutV1.composeBoard(physical: physical, candidates: candidates)
    }
}

/// One replayed inference call, written beside the benchmark output for
/// device-vs-replay and A/B-vs-baseline comparison.
struct ReplayTraceResult: Codable {
    let traceID: UUID
    let sessionID: UUID
    let pass: RecoveryPassKind
    let promptOverridden: Bool
    let recomposed: Bool
    let rawOutput: String
    let decodeError: String?
    let termination: String
    let latencyMilliseconds: Int
    let deviceRawOutput: String
    let matchesDevice: Bool

    init(row: EvidenceTraceRow, response: MLXRankResponse, promptOverridden: Bool, recomposed: Bool) {
        traceID = row.traceID
        sessionID = row.sessionID
        pass = row.pass
        self.promptOverridden = promptOverridden
        self.recomposed = recomposed
        rawOutput = response.trace.rawOutput
        decodeError = response.trace.decodeErrorDescription
        termination = response.trace.termination.rawValue
        latencyMilliseconds = response.trace.latencyMilliseconds
        deviceRawOutput = row.rawOutput
        matchesDevice = response.trace.rawOutput == row.rawOutput
    }

    enum CodingKeys: String, CodingKey {
        case traceID = "trace_id"
        case sessionID = "session_id"
        case pass
        case promptOverridden = "prompt_overridden"
        case recomposed
        case rawOutput = "raw_output"
        case decodeError = "decode_error"
        case termination
        case latencyMilliseconds = "latency_ms"
        case deviceRawOutput = "device_raw_output"
        case matchesDevice = "matches_device"
    }
}
