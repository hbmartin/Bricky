import ArgumentParser
import BrickyLanguage
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
        subcommands: [Replay.self, Recompose.self, WordingSheet.self, FMShadow.self, LatticeRows.self, SynthBundle.self]
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

    @Option(name: .customLong("model-revision"), help: "Revision of the weights actually in --model-dir; recorded as model_revision on replay rows.")
    var modelRevision: String?

    @Option(help: "Output NDJSON path for benchmark rows; per-trace results land beside it as <out>.traces.ndjson.")
    var out: String?

    @Option(name: .customLong("prompt-file"), help: "Replace every recorded rank prompt with this file's contents (A/B).")
    var promptFile: String?

    @Option(name: .customLong("max-tokens"), help: "Override rank maxTokens (A/B).")
    var maxTokens: Int?

    @Option(help: "Finalist vote rule: borda_dedup (the app's default) or borda_legacy (duplicates counted, as shipped before 2026-09).")
    var vote: RecoveryVoteRule = .bordaDedup

    @Option(help: "Decoder: legacy (the app's default, byte-identical to upstream), upstream (the pinned loop itself), or feed_all (feeds every sampled token to the KV cache).")
    var decode: DecodeMode = .legacy

    @Flag(help: "Recompose boards from captures + tiles instead of replaying the stored board images.")
    var recompose = false

    @Flag(name: .customLong("all-passes"), help: "Replay every rank trace, not only the finalist passes.")
    var allPasses = false

    @Flag(name: .customLong("dry-run"), help: "Validate bundle structure and exit without loading weights.")
    var dryRun = false

    @Flag(help: "Also replay step-check traces into <out>.checks.ndjson as vlm_check rows (false-complete first).")
    var checks = false

    @Flag(name: .customLong("unique-slots"), help: "Mask slot letters already in the ranking (the unique_slots variant).")
    var uniqueSlots = false

    @Option(help: "generate (the app's default) or probe: read the decision's probabilities from one prefill instead of generating JSON.")
    var scoring: ScoringMode = .generate

    @Option(name: .customLong("slot-order"), help: "sorted (baseline) or rotated: rotate finalist tiles across views. Requires --recompose.")
    var slotOrder: SlotOrder = .sorted

    @Option(help: "Board layout v1 (baseline) or v2 (tall finalist tiles, side-by-side check). v2 requires --recompose.")
    var board: BoardLayoutVersion = .v1

    @Option(help: "Tile labels slot_step (baseline) or slot. slot requires --recompose.")
    var labels: TileLabelStyle = .slotAndStep

    @Option(name: .customLong("prompt-style"), help: "Replace recorded prompts with baseline or dynamic_range wording.")
    var promptStyle: PromptStyle?

    @Option(name: .customLong("image-side"), help: "Resize boards to this side before the vision encoder (baseline 1024).")
    var imageSide: Int = RecoveryInferenceVariant.baselineImageSide

    @Option(name: .customLong("check-target"), help: "Step checks: guide_camera (baseline) or registered. A target other than the recorded one uses the check's alternate tile and needs --recompose.")
    var checkTarget: CheckTarget = .guideCamera

    @Option(help: "A/B arm label recorded on every row (e.g. control, B).")
    var arm: String?

    @Option(help: #"A full inference variant as JSON, e.g. {"decode":"feed_all","vote":"borda_dedup"}; overrides --decode and --vote."#)
    var variant: String?

    /// The variant this replay runs: the JSON if given, else the flags.
    private func resolvedVariant() throws -> RecoveryInferenceVariant {
        var resolved = RecoveryInferenceVariant(
            decode: decode, vote: vote, uniqueSlots: uniqueSlots, scoring: scoring, slotOrder: slotOrder,
            boardLayout: board, labels: labels, promptStyle: promptStyle ?? .baseline, imageSide: imageSide,
            checkTarget: checkTarget, armID: arm
        )
        if let variant {
            resolved = try JSONDecoder().decode(RecoveryInferenceVariant.self, from: Data(variant.utf8))
            if resolved.armID == nil { resolved.armID = arm }
        }
        do {
            try resolved.validate()
        } catch {
            throw ValidationError("\(error)")
        }
        return resolved
    }

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
        guard let modelDirectory, let out, let modelRevision else {
            throw ValidationError("--model-dir, --out, and --model-revision are required unless --dry-run is set.")
        }
        let promptOverride = try promptFile.map { try String(contentsOfFile: $0, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) }
        let modelURL = URL(fileURLWithPath: modelDirectory)
        let runtime = MLXRecoveryRuntime()
        let encoder = EvidenceSchema.encoder()
        let variant = try resolvedVariant()
        // These change pixels: only a board rebuilt from tiles can show them.
        if !recompose, variant.slotOrder != .sorted || variant.boardLayout != .v1 || variant.labels != .slotAndStep {
            throw ValidationError("--slot-order rotated, --board v2, and --labels slot need --recompose to rebuild the boards.")
        }
        var benchmarkLines: [Data] = []
        var traceLines: [Data] = []
        var checkLines: [Data] = []

        for session in sessions {
            let expectedStepID = session.file.groundTruth.expectedStepID
            let rankRows = session.traceRows
                .filter { $0.pass != .check }
                .filter { allPasses || $0.pass == .finalist }
            var finalistReplays: [(row: EvidenceTraceRow, output: MLXRankOutput?, probe: ProbeReadout?)] = []
            // Every replayed call counts: with --all-passes this is the whole
            // hierarchy's inference cost, as the device's wall clock is.
            var tally = ReplayAggregation.CallTally()
            for recordedRow in rankRows {
                // Rotation reassigns the recorded tiles to new slots; the
                // remapped row is what the model sees and what is scored.
                let row = recordedRow.pass == .finalist && variant.slotOrder == .rotated
                    ? recordedRow.withSlotsRotated(viewIndex: recordedRow.passIndex)
                    : recordedRow
                let board = try boardURL(for: row, in: session, variant: variant)
                let prompt = RecoveryPrompts.replayRank(
                    recorded: row.prompt, override: promptOverride, explicitStyle: promptStyle,
                    variant: variant, slotCount: row.candidateStepIDs.count
                )
                let response = try await runtime.rankWithTrace(
                    imageURL: board,
                    prompt: prompt,
                    candidateCount: row.candidateStepIDs.count,
                    modelDirectory: modelURL,
                    maxTokens: maxTokens,
                    decode: variant.decode,
                    uniqueSlots: variant.uniqueSlots,
                    scoring: variant.scoring,
                    imageSide: variant.imageSide
                )
                tally.add(latencyMilliseconds: response.trace.latencyMilliseconds)
                if row.pass == .finalist {
                    finalistReplays.append((row, response.output, response.trace.probe))
                }
                let decision = ReplayDecision(rawOutput: response.trace.rawOutput)
                traceLines.append(try encoder.encode(ReplayTraceResult(
                    row: row, trace: response.trace, promptOverridden: promptOverride != nil, recomposed: recompose,
                    variant: variant, decision: decision,
                    outcome: ReplayAggregation.passOutcome(row: row, decision: decision, expectedStepID: expectedStepID),
                    modelRevision: modelRevision
                )))
                print("replayed \(row.pass.rawValue) \(row.traceID.uuidString.prefix(8)) → \(response.trace.termination.rawValue), \(response.trace.latencyMilliseconds) ms")
            }
            if checks {
                for recordedRow in session.traceRows where recordedRow.pass == .check {
                    // Every row replays at the variant's target, so the
                    // variant_id stays honest; a check never rendered at
                    // that target has no row in this arm.
                    guard let row = recordedRow.retargeted(to: variant.checkTarget) else {
                        print("check \(recordedRow.traceID.uuidString.prefix(8)) has no \(variant.checkTarget.rawValue) tile — no vlm_check row")
                        continue
                    }
                    if row.checkTarget != recordedRow.checkTarget, !recompose {
                        print("check \(recordedRow.traceID.uuidString.prefix(8)) was recorded at \(recordedRow.checkTarget.rawValue); replaying it at \(row.checkTarget.rawValue) needs --recompose — no vlm_check row")
                        continue
                    }
                    let response = try await runtime.checkStepWithTrace(
                        imageURL: try boardURL(for: row, in: session, variant: variant),
                        prompt: RecoveryPrompts.replayCheck(recorded: row.prompt, explicitStyle: promptStyle, variant: variant),
                        modelDirectory: modelURL,
                        decode: variant.decode,
                        scoring: variant.scoring,
                        imageSide: variant.imageSide
                    )
                    guard let expected = ReplayAggregation.expectedCheckVerdict(
                        row: row, expectedCompletedCount: session.file.groundTruth.expectedCompletedCount
                    ) else {
                        print("check \(row.traceID.uuidString.prefix(8)) has no labeled step count — no vlm_check row")
                        continue
                    }
                    checkLines.append(try encoder.encode(ReplayCheckRow(
                        row: row, trace: response.trace, expectedVerdict: expected,
                        variant: variant, modelRevision: modelRevision
                    )))
                    print("replayed check \(row.traceID.uuidString.prefix(8)) → \(response.output?.result ?? "undecodable") (expected \(expected))")
                }
            }
            if let rowData = try benchmarkRow(session: session, finalistReplays: finalistReplays,
                                              tally: tally, replayModelRevision: modelRevision,
                                              variant: variant) {
                benchmarkLines.append(rowData)
            } else if session.file.groundTruth.kind == .unlabeled {
                print("session \(session.file.sessionID.uuidString.prefix(8)) is unlabeled — no benchmark row")
            } else {
                // Corpus accounting: a labeled geometric-only session has no
                // rank traces to replay, and geometric replay does not exist
                // yet, so the row it would contribute is explicitly missing.
                print("session \(session.file.sessionID.uuidString.prefix(8)) is labeled but has no replayable finalist rank traces (geometric-only) — no benchmark row")
            }
        }

        try write(lines: benchmarkLines, to: URL(fileURLWithPath: out))
        try write(lines: traceLines, to: URL(fileURLWithPath: out + ".traces.ndjson"))
        if checks {
            try write(lines: checkLines, to: URL(fileURLWithPath: out + ".checks.ndjson"))
            print("wrote \(checkLines.count) vlm_check rows to \(out).checks.ndjson")
        }
        print("wrote \(benchmarkLines.count) benchmark rows to \(out)")
    }

    private func boardURL(for row: EvidenceTraceRow, in session: EvidenceBundleReader.Session, variant: RecoveryInferenceVariant) throws -> URL {
        guard recompose else {
            return session.directory.appendingPathComponent(row.boardRelativePath)
        }
        let recomposed = try BoardRecomposer.recompose(row: row, in: session, layout: variant.boardLayout, labels: variant.labels)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bricky-harness-\(row.traceID.uuidString).jpg")
        try RecoveryBoardLayoutV1.writeJPEG(recomposed, to: url)
        return url
    }

    /// Aggregates replayed finalist passes through the same `RecoveryVote`
    /// the app's estimator uses, so replay and device cannot drift apart.
    private func benchmarkRow(
        session: EvidenceBundleReader.Session,
        finalistReplays: [(row: EvidenceTraceRow, output: MLXRankOutput?, probe: ProbeReadout?)],
        tally: ReplayAggregation.CallTally,
        replayModelRevision: String,
        variant: RecoveryInferenceVariant
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
        let views = finalistReplays.compactMap { row, output, probe -> RecoveryVoteView<String>? in
            guard let output, output.status == "matched" else { return nil }
            return RecoveryVoteView(ranking: output.ranking, candidateForSlot: row.candidateStepIDs, slotProbabilities: probe?.options)
        }
        let outcome = RecoveryVote.aggregate(views: views, finalists: finalists, rule: variant.vote)
        let ranked = outcome.map { Array($0.ordered.prefix(3)) } ?? []
        let certainty = outcome?.certainty ?? .insufficient
        let row = RecoveryBenchmarkV1(
            schemaVersion: RecoveryBenchmarkV1.schemaVersion,
            fixtureID: session.file.sessionID.uuidString,
            instructionSHA256: session.file.instructionSHA256,
            pyldraw3Version: "1.5.0",
            partPackVersion: "2026-07",
            expectedStepID: expectedStepID,
            candidateSlots: slotSource.candidateStepIDs,
            boardRelativePaths: finalistReplays.map(\.row.boardRelativePath),
            cameraMetadata: session.file.captures.map(\.benchmarkCameraMetadata),
            expectedStepIndex: expectedCount,
            rankedStepIDs: ranked,
            certainty: certainty,
            // Replay reconstructs the estimate from recorded VLM rank traces
            // alone, so a replayed row is `.vlm` by construction regardless of
            // what produced the original estimate on device.
            estimatorMethod: .vlm,
            // The revision of the weights this replay actually loaded from
            // --model-dir — never the source session's revision, which may
            // differ in an A/B and would misattribute the scores.
            modelRevision: replayModelRevision,
            // Replay rows must never enter a release corpus as device rows.
            deviceModel: "replay:\(DeviceIdentity.modelIdentifier)",
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            latencyMilliseconds: tally.latencyMilliseconds,
            // The kernel's lifetime peak, not whatever the footprint happens
            // to be when the row is written.
            memoryPeakBytes: ProcessMemorySnapshot.current()?.lifetimePeakBytes ?? ProcessFootprint.currentBytes() ?? 0,
            topStepIndex: ranked.first.flatMap(Self.stepNumber(from:)),
            physicalCase: session.file.staged?.physicalCase,
            authoredModelID: session.file.authoredModelID.uuidString,
            legalUseConfirmed: session.file.staged?.legalUseConfirmed,
            lightingCondition: session.file.staged?.lighting.rawValue,
            captureAngle: session.file.captures.map(\.angle).joined(separator: ","),
            occlusionCondition: session.file.staged?.occlusion.rawValue,
            captureElevationDegrees: session.file.captures.benchmarkElevationDegrees,
            variantID: variant.id,
            osBuild: DeviceIdentity.osBuild,
            gpuArchitecture: DeviceIdentity.gpuArchitecture,
            vlmCalls: tally.calls,
            latencyScope: (allPasses ? ReplayAggregation.LatencyScope.allPasses : .finalistsOnly).rawValue
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

struct WordingSheet: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wording-sheet",
        abstract: "Build the blinded repair-wording preference sheet from device wording.ndjson pairs (ADR 0017).",
        discussion: """
        Give the sheet to the rater and keep the key. Each row places the
        template and the model's sentence as A or B at random; the rater
        fills `choice` with A, B or =. Then:
        python3 Tools/RecoveryEvaluation/score_wording_ab.py --sheet <sheet> --key <key>
        Device pairs only decide the default (a Mac is not the phone's model tier).
        """
    )

    @Option(help: "An unzipped evidence bundle directory; repeat for several.")
    var bundle: [String]

    @Option(name: .customLong("out-sheet"), help: "CSV for the rater.")
    var outSheet: String

    @Option(name: .customLong("out-key"), help: "CSV that unblinds the sheet; keep it from the rater.")
    var outKey: String

    @Option(help: "Seed for the pair order and A/B placement.")
    var seed: UInt64 = 7

    mutating func run() throws {
        var records: [RepairWordingRecordV1] = []
        for path in bundle {
            let reader = try EvidenceBundleReader(bundleDirectory: URL(fileURLWithPath: path))
            records += try reader.loadSessions().flatMap(\.wordingRecords)
        }
        let (pairs, summary) = WordingPreferenceSheet.pairs(from: records, seed: seed)
        try WordingPreferenceSheet.sheetCSV(pairs).write(toFile: outSheet, atomically: true, encoding: .utf8)
        try WordingPreferenceSheet.keyCSV(pairs).write(toFile: outKey, atomically: true, encoding: .utf8)
        print("""
        wording attempts \(summary.attempts): \(summary.accepted) accepted, \(summary.identical) identical to the template, \
        \(summary.duplicates) repeats; \(summary.pairs) pairs on the sheet
        """)
    }
}

struct FMShadow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fm-shadow",
        abstract: "Replay a bundle's photo checks through the Foundation Models advisor (informational, ADR 0018).",
        discussion: """
        Needs macOS 27 with Apple Intelligence on. Writes shadow_check rows
        (provenance replay) to --out, and vlm_check-shaped rows of the
        advisor's standalone verdict to <out>.checks.ndjson, so
        compare_arms.py --primary check_correct can pair it with a VLM
        replay. A Mac is not the phone's model tier: these rows guide prompt
        work and never decide ADR 0018, and release mode refuses them.
        """
    )

    @Option(help: "Path to an unzipped evidence bundle directory.")
    var bundle: String

    @Option(help: "Output NDJSON path for shadow_check rows; <out>.checks.ndjson is written beside it.")
    var out: String

    mutating func run() async throws {
        #if canImport(FoundationModels)
        guard #available(macOS 27.0, *) else {
            throw ValidationError("fm-shadow needs macOS 27: the system model's image input is 27-only")
        }
        if let reason = FoundationModelsRepairWording.readiness() {
            throw ValidationError("the system model is not ready (\(reason)); turn on Apple Intelligence")
        }
        let advisor = FoundationModelsStepCheckAdvisor()
        let reader = try EvidenceBundleReader(bundleDirectory: URL(fileURLWithPath: bundle))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var shadowLines: [Data] = []
        var checkLines: [Data] = []
        var skipped = 0
        let host = "replay:\(DeviceIdentity.modelIdentifier)"
        let osBuild = DeviceIdentity.osBuild
        for session in try reader.loadSessions() {
            let truth = session.file.groundTruth
            let labelKind: VLMCheckRowV1.LabelKind? = switch truth.kind {
            case .staged: .staged
            case .confirmed: .confirmed
            case .unlabeled: nil
            }
            for row in session.traceRows where row.pass == .check {
                guard let labelKind,
                      let expected = ReplayAggregation.expectedCheckVerdict(row: row, expectedCompletedCount: truth.expectedCompletedCount),
                      let stepIndex = row.candidateStepIndices["A"],
                      let captureID = row.captureID,
                      let tile = row.tileRelativePaths["A"],
                      let photo = try? Data(contentsOf: session.directory.appendingPathComponent("captures/\(captureID.uuidString).jpg")),
                      let target = try? Data(contentsOf: session.directory.appendingPathComponent(tile)) else {
                    skipped += 1
                    continue
                }
                let advice = await advisor.advise(StepCheckAdviceInput(
                    photoJPEG: photo, targetJPEG: target, deltaBox: row.checkGeometry?.deltaBox,
                    targetIsRegistered: row.checkTarget == .registered, stepNumber: stepIndex + 1
                ))
                let primary = CheckVerdictV1(rawValue: ReplayDecision(rawOutput: row.rawOutput)?.result ?? "") ?? .uncertain
                let shadow = ShadowCheckRowV1(
                    provenance: "replay", fixtureID: row.traceID.uuidString, sessionID: session.file.sessionID,
                    expectedVerdict: expected, primaryVerdict: primary.rawValue,
                    standaloneVerdict: advice.standalone?.rawValue ?? "none", closedAnswer: advice.closed?.rawValue,
                    mergedVerdict: ShadowMerge.merge(primary: primary, advice: advice).rawValue,
                    advisor: "foundation_models", checkTarget: row.checkTarget.rawValue,
                    latencyMilliseconds: advice.milliseconds, deviceModel: host, osBuild: osBuild,
                    labelKind: labelKind, authoredModelID: session.file.authoredModelID.uuidString, stepIndex: stepIndex,
                    physicalCase: session.file.staged?.physicalCase, legalUseConfirmed: session.file.staged?.legalUseConfirmed
                )
                shadowLines.append(try encoder.encode(shadow))
                checkLines.append(try encoder.encode(FMShadowCheckRow(
                    fixtureID: row.traceID.uuidString, sessionID: session.file.sessionID, expectedVerdict: expected,
                    producedVerdict: advice.standalone?.rawValue ?? "uncertain", decodeFailed: advice.standalone == nil,
                    latencyMilliseconds: advice.milliseconds, variantID: "fm_shadow", modelRevision: "system:\(osBuild ?? "unknown")",
                    deviceModel: host
                )))
                print("check \(row.traceID.uuidString.prefix(8)): VLM \(primary.rawValue), advisor \(advice.standalone?.rawValue ?? advice.standaloneOutcome), closed \(advice.closed?.rawValue ?? advice.closedOutcome)")
            }
        }
        try Self.write(shadowLines, to: URL(fileURLWithPath: out))
        try Self.write(checkLines, to: URL(fileURLWithPath: "\(out).checks.ndjson"))
        print("advised \(shadowLines.count) labeled checks (\(skipped) skipped: unlabeled or missing images); informational only")
        #else
        throw ValidationError("built without FoundationModels: build bricky-harness with Xcode 27")
        #endif
    }

    private static func write(_ lines: [Data], to url: URL) throws {
        var data = Data()
        for line in lines {
            data.append(line)
            data.append(UInt8(ascii: "\n"))
        }
        try data.write(to: url, options: .atomic)
    }
}

/// The advisor's standalone verdict as a `vlm_check` replay row, so a paired
/// comparison against the VLM's replay arm is one compare_arms call.
struct FMShadowCheckRow: Encodable {
    let kind = "vlm_check"
    let schemaVersion = 1
    let provenance = "replay"
    let fixtureID: String
    let sessionID: UUID
    let expectedVerdict: String
    let producedVerdict: String
    let decodeFailed: Bool
    let latencyMilliseconds: Int
    let variantID: String
    let modelRevision: String
    let deviceModel: String

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
        case modelRevision = "model_revision"
        case deviceModel = "device_model"
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
    static func recompose(
        row: EvidenceTraceRow,
        in session: EvidenceBundleReader.Session,
        layout: BoardLayoutVersion = .v1,
        labels: TileLabelStyle = .slotAndStep
    ) throws -> CGImage {
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
        switch layout {
        case .v1 where labels == .slotAndStep:
            return try RecoveryBoardLayoutV1.composeBoard(physical: physical, candidates: candidates)
        case .v2 where row.pass == .check:
            guard let target = candidates.first else { throw ValidationError("check trace \(row.traceID) has no tile") }
            return try RecoveryBoardLayoutV2.composeCheckBoard(physical: physical, target: target, labels: labels)
        default:
            // V2's grid fallback draws V1 geometry with the chosen labels.
            return try RecoveryBoardLayoutV2.composeBoard(physical: physical, candidates: candidates, labels: labels)
        }
    }
}

extension EvidenceTraceRow {
    /// The same trace with its candidates moved to rotated slots, as the app
    /// would have placed them for view `viewIndex`.
    func withSlotsRotated(viewIndex: Int) -> EvidenceTraceRow {
        let slots = candidateStepIDs.keys.sorted()
        let rotated = SlotAssignment.rotated(slots, viewIndex: viewIndex)
        var ids: [String: String] = [:], indices: [String: Int] = [:], tiles: [String: String] = [:]
        for (newSlot, oldSlot) in zip(slots, rotated) {
            ids[newSlot] = candidateStepIDs[oldSlot]
            indices[newSlot] = candidateStepIndices[oldSlot]
            tiles[newSlot] = tileRelativePaths[oldSlot]
        }
        return EvidenceTraceRow(
            traceVersion: traceVersion, traceID: traceID, sessionID: sessionID, pass: pass, passIndex: passIndex,
            captureID: captureID, captureAngle: captureAngle, boardRelativePath: boardRelativePath,
            tileRelativePaths: tiles, candidateStepIndices: indices, candidateStepIDs: ids, prompt: prompt,
            schemaJSON: schemaJSON, maxTokens: maxTokens, rawOutput: rawOutput, decodeError: decodeError,
            termination: termination, generatedTokens: generatedTokens, latencyMilliseconds: latencyMilliseconds,
            memoryFootprintBytes: memoryFootprintBytes, modelRevision: modelRevision, createdAt: createdAt,
            variant: variant, inference: inference, conditions: conditions, readouts: readouts, probe: probe,
            alternateTileRelativePaths: alternateTileRelativePaths
        )
    }
}

/// One replayed inference call, written beside the benchmark output for
/// device-vs-replay and A/B-vs-baseline comparison.
/// One replayed rank call, beside what the device decided for it. Pass-level
/// correctness and slot letters make these rows pairable by trace for an A/B
/// (`compare_arms.py`), including the slot-bias histogram.
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
    /// Same decision as the device (status and ranking), ignoring spacing.
    let matchesDevice: Bool
    /// Byte-identical output, the stricter check a decoder refactor needs.
    let matchesDeviceRaw: Bool
    let variant: RecoveryInferenceVariant
    let variantID: String
    let decision: ReplayDecision?
    let outcome: ReplayAggregation.PassOutcome
    let inference: InferenceTelemetry?
    let readouts: [DecisionReadout]?
    /// The weights this replay ran (`--model-revision`), so `compare_arms.py`
    /// can refuse to pair arms that ran different models.
    let modelRevision: String?

    init(
        row: EvidenceTraceRow, trace: MLXGenerationTrace, promptOverridden: Bool, recomposed: Bool,
        variant: RecoveryInferenceVariant, decision: ReplayDecision?, outcome: ReplayAggregation.PassOutcome,
        modelRevision: String?
    ) {
        traceID = row.traceID
        sessionID = row.sessionID
        pass = row.pass
        self.promptOverridden = promptOverridden
        self.recomposed = recomposed
        rawOutput = trace.rawOutput
        decodeError = trace.decodeErrorDescription
        termination = trace.termination.rawValue
        latencyMilliseconds = trace.latencyMilliseconds
        deviceRawOutput = row.rawOutput
        matchesDevice = ReplayAggregation.decisionsMatch(decision, ReplayDecision(rawOutput: row.rawOutput))
        matchesDeviceRaw = trace.rawOutput == row.rawOutput
        self.variant = variant
        variantID = variant.id
        self.decision = decision
        self.outcome = outcome
        inference = trace.inference
        readouts = trace.readouts
        self.modelRevision = modelRevision
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
        case matchesDeviceRaw = "matches_device_raw"
        case variant
        case variantID = "variant_id"
        case decision
        case outcome
        case inference
        case readouts
        case modelRevision = "model_revision"
    }
}

/// A replayed step check, scored by `score_results.py` as kind `vlm_check`:
/// the VLM check's false-complete rate, which ADR 0008's yes-bias concern
/// makes the number to watch. Replay rows, so never release evidence.
struct ReplayCheckRow: Encodable {
    let kind = "vlm_check"
    let schemaVersion = 1
    let provenance = "replay"
    let fixtureID: String
    let sessionID: UUID
    let expectedVerdict: String
    let producedVerdict: String
    let decodeFailed: Bool
    let deviceVerdict: String?
    let matchesDevice: Bool
    let latencyMilliseconds: Int
    let variantID: String
    let modelRevision: String
    let deviceModel: String

    init(row: EvidenceTraceRow, trace: MLXGenerationTrace, expectedVerdict: String,
         variant: RecoveryInferenceVariant, modelRevision: String) {
        let decision = ReplayDecision(rawOutput: trace.rawOutput)
        let device = ReplayDecision(rawOutput: row.rawOutput)
        fixtureID = row.traceID.uuidString
        sessionID = row.sessionID
        self.expectedVerdict = expectedVerdict
        // An undecodable answer is no verdict: scored as uncertain, flagged.
        producedVerdict = decision?.result ?? "uncertain"
        decodeFailed = decision?.result == nil
        deviceVerdict = device?.result
        matchesDevice = ReplayAggregation.decisionsMatch(decision, device)
        latencyMilliseconds = trace.latencyMilliseconds
        variantID = variant.id
        self.modelRevision = modelRevision
        deviceModel = "replay:\(DeviceIdentity.modelIdentifier)"
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case schemaVersion = "schema_version"
        case provenance
        case fixtureID = "fixture_id"
        case sessionID = "session_id"
        case expectedVerdict = "expected_verdict"
        case producedVerdict = "produced_verdict"
        case decodeFailed = "decode_failed"
        case deviceVerdict = "device_verdict"
        case matchesDevice = "matches_device"
        case latencyMilliseconds = "latency_ms"
        case variantID = "variant_id"
        case modelRevision = "model_revision"
        case deviceModel = "device_model"
    }
}

extension RecoveryVoteRule: ExpressibleByArgument {}
extension DecodeMode: ExpressibleByArgument {}
extension ScoringMode: ExpressibleByArgument {}
extension SlotOrder: ExpressibleByArgument {}
extension BoardLayoutVersion: ExpressibleByArgument {}
extension TileLabelStyle: ExpressibleByArgument {}
extension PromptStyle: ExpressibleByArgument {}
extension CheckTarget: ExpressibleByArgument {}
