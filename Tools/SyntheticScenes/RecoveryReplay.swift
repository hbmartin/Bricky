import Foundation
import simd

extension SyntheticRGBDMain.RecoveryArm {
    /// The estimator configuration the arm runs: the tie-break is the only
    /// difference (ADR 0010).
    var configuration: GeometricRecoveryEstimator.Configuration {
        var configuration = GeometricRecoveryEstimator.Configuration()
        configuration.consistencyTieBreak = self == .tiebreak
        return configuration
    }

    /// The `variant_id` a replayed row carries, so `compare_arms.py` pairs
    /// the arms' rows by session.
    var variantID: String { "recovery_arm=\(rawValue)" }
}

/// Replays a bundle's geometric recoveries on a Mac (`--replay-bundle
/// --suite recovery`). Each session's center depth frame is fitted again
/// from the alignment the device fit it from, through
/// `GeometricRecoveryReplay`, and the fits are compared with the device's
/// `fits.ndjson`. Labeled sessions become `RecoveryBenchmarkV1` rows with
/// `estimator_method: geometric` and `device_model: replay:<mac>`, which the
/// release preflight refuses. iOS and macOS may rasterize differently, so a
/// fit mismatch on a device bundle is reported, not fatal; a bundle written
/// on this Mac must match exactly (`--require-match`).
enum RecoveryReplay {
    struct Summary {
        var sessions = 0
        var replayed = 0
        var fitsMatched = 0
        var estimatesCompared = 0
        var estimatesMatched = 0
        var skippedNoDepth = 0
        var skippedNoAlignment = 0
        var skippedOtherModel = 0
        var errored = 0

        /// Whether `--require-match` passes: something was replayed, nothing
        /// this model's was skipped or failed, and every fit and comparable
        /// estimate agreed. Another model's sessions do not count against it.
        var allMatched: Bool {
            replayed > 0 && skippedNoDepth == 0 && skippedNoAlignment == 0 && errored == 0
                && fitsMatched == replayed && estimatesMatched == estimatesCompared
        }

        var line: String {
            "replayed \(replayed)/\(sessions) sessions; fits identical on \(fitsMatched)/\(replayed); "
                + "estimate agrees on \(estimatesMatched)/\(estimatesCompared); skipped: no depth \(skippedNoDepth), "
                + "no alignment \(skippedNoAlignment), other model \(skippedOtherModel); errored \(errored)"
        }
    }

    struct Output {
        var rows: [String] = []
        var fits: [String] = []
        var summary = Summary()
    }

    static func run(
        bundle: URL, plan: InstructionPlan, sourceIdentity: String, geometry: PlacementGeometry,
        sourceRoot: URL, partPackRoot: URL, renderer: ExpectedDepthRenderer, arm: SyntheticRGBDMain.RecoveryArm
    ) async throws -> Output {
        let reader = try EvidenceBundleReader(bundleDirectory: bundle)
        let issues = reader.validate()
        guard issues.isEmpty else {
            throw CLIError("invalid bundle:\n" + issues.joined(separator: "\n"))
        }
        let encoder = EvidenceSchema.encoder()
        var output = Output()
        // The reader orders by creation time alone; ties fall back to the
        // session id so two runs over one bundle write identical files.
        let sessions = try reader.loadSessions().sorted { lhs, rhs in
            if lhs.file.createdAt != rhs.file.createdAt { return lhs.file.createdAt < rhs.file.createdAt }
            return lhs.file.sessionID.uuidString < rhs.file.sessionID.uuidString
        }
        for session in sessions {
            output.summary.sessions += 1
            let name = String(session.file.sessionID.uuidString.prefix(8))
            guard session.file.instructionSHA256 == sourceIdentity else {
                output.summary.skippedOtherModel += 1
                continue
            }
            if let pack = session.file.partPackVersion, pack != LDrawInstructionParser.partPackVersion {
                print("session \(name): recorded with part pack \(pack), replaying with \(LDrawInstructionParser.partPackVersion); fits may differ")
            }
            let input: GeometricRecoveryReplay.Input
            do {
                input = try GeometricRecoveryReplay.input(for: session)
            } catch GeometricRecoveryReplay.Skip.noDepthFrame {
                output.summary.skippedNoDepth += 1
                continue
            } catch GeometricRecoveryReplay.Skip.noAlignment {
                print("session \(name): depth frame has no recorded alignment (recorded before 2026-10-08); skipped")
                output.summary.skippedNoAlignment += 1
                continue
            }
            let outcome = try await GeometricRecoveryReplay.replay(
                input, sessionID: session.file.sessionID, plan: plan, geometry: geometry,
                sourceRoot: sourceRoot, partPackRoot: partPackRoot, renderer: renderer, configuration: arm.configuration
            )
            output.summary.replayed += 1
            if let error = outcome.error {
                print("session \(name): estimator failed: \(error)")
                output.summary.errored += 1
            }
            let fitsMatch = GeometricRecoveryReplay.fitsMatch(recorded: session.fitRecords, replayed: outcome.fits)
            output.summary.fitsMatched += fitsMatch ? 1 : 0
            let estimateMatch = GeometricRecoveryReplay.estimateMatches(outcome.estimate, recorded: session.file.estimate)
            if let estimateMatch {
                output.summary.estimatesCompared += 1
                output.summary.estimatesMatched += estimateMatch ? 1 : 0
            }
            let verdict = outcome.estimate?.rankedStepIDs.first ?? "insufficient"
            let estimateNote = estimateMatch.map { $0 ? "same" : "differs" } ?? "n/a"
            print("session \(name): \(verdict); fits \(fitsMatch ? "same" : "differ") (\(outcome.fits.count) vs \(session.fitRecords.count)); estimate \(estimateNote)")
            for fit in outcome.fits {
                output.fits.append(String(decoding: try encoder.encode(fit), as: UTF8.self))
            }
            if let row = try benchmarkRow(session: session, plan: plan, outcome: outcome, arm: arm) {
                output.rows.append(String(decoding: try encoder.encode(row), as: UTF8.self))
            }
        }
        return output
    }

    /// A labeled session's row; nil for an unlabeled one.
    static func benchmarkRow(
        session: EvidenceBundleReader.Session, plan: InstructionPlan,
        outcome: GeometricRecoveryReplay.Outcome, arm: SyntheticRGBDMain.RecoveryArm
    ) throws -> RecoveryBenchmarkV1? {
        let truth = session.file.groundTruth
        guard truth.kind != .unlabeled, let expectedCount = truth.expectedCompletedCount else { return nil }
        let inputs = RecoveryBenchmarkInputs(plan: plan, expectedCompletedCount: expectedCount)
        let ranked = outcome.estimate?.rankedStepIDs ?? []
        let staged = session.file.staged
        let memory = ProcessFootprint.currentBytes() ?? 0
        return RecoveryBenchmarkV1(
            schemaVersion: RecoveryBenchmarkV1.schemaVersion,
            fixtureID: session.file.sessionID.uuidString,
            instructionSHA256: session.file.instructionSHA256,
            // As bricky-harness writes it (AppConfig.pyldraw3Version).
            pyldraw3Version: "1.5.0",
            // The pack this replay rendered with, not the session's.
            partPackVersion: LDrawInstructionParser.partPackVersion,
            expectedStepID: truth.expectedStepID ?? inputs.expectedStepID,
            // A geometric estimate shows no board; `scored_step_ids` says
            // which steps it was asked to tell apart.
            candidateSlots: [:],
            boardRelativePaths: [],
            cameraMetadata: session.file.captures.map(\.benchmarkCameraMetadata),
            expectedStepIndex: inputs.expectedCompletedCount,
            rankedStepIDs: ranked,
            certainty: outcome.estimate?.certainty ?? .insufficient,
            estimatorMethod: .geometric,
            modelRevision: outcome.estimate?.modelRevision ?? GeometricRecoveryEstimator.revision,
            // Replay rows must never enter a release corpus as device rows.
            deviceModel: "replay:\(DeviceIdentity.modelIdentifier)",
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            latencyMilliseconds: outcome.latencyMilliseconds,
            memoryPeakBytes: memory,
            topStepIndex: ranked.first.flatMap { inputs.stepNumbersByID[$0] },
            physicalCase: staged?.physicalCase,
            authoredModelID: session.file.authoredModelID.uuidString,
            legalUseConfirmed: staged?.legalUseConfirmed,
            lightingCondition: staged?.lighting.rawValue,
            captureAngle: session.file.captures.map(\.angle).joined(separator: ","),
            occlusionCondition: staged?.occlusion.rawValue,
            captureElevationDegrees: session.file.captures.benchmarkElevationDegrees,
            variantID: arm.variantID,
            osBuild: DeviceIdentity.osBuild,
            gpuArchitecture: DeviceIdentity.gpuArchitecture,
            vlmCalls: 0,
            latencyScope: ReplayAggregation.LatencyScope.geometricEstimate.rawValue,
            scoredStepIDs: outcome.fits.isEmpty ? nil : outcome.fits.scoredStepIDs
        )
    }
}
