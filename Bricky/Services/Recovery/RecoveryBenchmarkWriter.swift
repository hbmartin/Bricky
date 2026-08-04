import Foundation

/// Ground-truth mapping a benchmark row needs from the instruction plan.
/// `expected_step_index` uses authored step numbers with 0 meaning step zero
/// (not started) — the same semantics as the scorer's example fixtures.
struct RecoveryBenchmarkInputs: Sendable {
    let expectedCompletedCount: Int
    let expectedStepID: String
    /// Authored step number by step identifier, including step zero → 0.
    let stepNumbersByID: [String: Int]

    init(expectedCompletedCount: Int, expectedStepID: String, stepNumbersByID: [String: Int]) {
        self.expectedCompletedCount = expectedCompletedCount
        self.expectedStepID = expectedStepID
        self.stepNumbersByID = stepNumbersByID
    }

    init(plan: InstructionPlan, expectedCompletedCount: Int) {
        let clamped = min(max(0, expectedCompletedCount), plan.steps.count)
        var numbers = [plan.stepZeroID: 0]
        for step in plan.steps {
            numbers[step.id] = step.index
        }
        self.init(
            expectedCompletedCount: clamped,
            expectedStepID: clamped == 0 ? plan.stepZeroID : plan.steps[clamped - 1].id,
            stepNumbersByID: numbers
        )
    }
}

extension RecoveryEvidenceRecorder {
    /// Emits the session's `RecoveryBenchmarkV1` row to `benchmark.ndjson` —
    /// the producer `Tools/RecoveryEvaluation/score_results.py` never had.
    /// Requires a labeled, finalized session with an estimate.
    func writeBenchmarkRow(inputs: RecoveryBenchmarkInputs) {
        perform("write benchmark row") {
            guard session.groundTruth.kind != .unlabeled, let estimate = session.estimate else { return }
            let rows = loadTraceRows()
            let voting = rows.filter { $0.pass == .finalist || $0.pass == .check }
            let slotSource = voting.first(where: { $0.captureAngle == CaptureAngle.center.rawValue }) ?? voting.first
            let row = RecoveryBenchmarkV1(
                schemaVersion: RecoveryBenchmarkV1.schemaVersion,
                fixtureID: sessionID.uuidString,
                instructionSHA256: session.instructionSHA256,
                pyldraw3Version: AppConfig.pyldraw3Version,
                partPackVersion: LDrawPartPackManager.version,
                expectedStepID: inputs.expectedStepID,
                candidateSlots: slotSource?.candidateStepIDs ?? [:],
                boardRelativePaths: voting.map(\.boardRelativePath),
                cameraMetadata: session.captures.map(Self.cameraMetadata),
                expectedStepIndex: inputs.expectedCompletedCount,
                rankedStepIDs: estimate.rankedStepIDs,
                certainty: RecoveryCertainty(rawValue: estimate.certainty) ?? .insufficient,
                deviceModel: session.deviceModel,
                operatingSystem: session.operatingSystem,
                latencyMilliseconds: estimate.latencyMilliseconds,
                memoryPeakBytes: rows.compactMap(\.memoryFootprintBytes).max() ?? 0,
                topStepIndex: estimate.rankedStepIDs.first.flatMap { inputs.stepNumbersByID[$0] },
                physicalCase: session.staged?.physicalCase,
                authoredModelID: session.authoredModelID.uuidString,
                legalUseConfirmed: session.staged?.legalUseConfirmed,
                lightingCondition: session.staged?.lighting.rawValue,
                captureAngle: session.captures.map(\.angle).joined(separator: ","),
                occlusionCondition: session.staged?.occlusion.rawValue
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var line = try encoder.encode(row)
            line.append(UInt8(ascii: "\n"))
            try line.write(to: sessionDirectory.appendingPathComponent("benchmark.ndjson"), options: .atomic)
        }
    }

    private static func cameraMetadata(for capture: EvidenceCaptureRecord) -> [String: Float] {
        var metadata: [String: Float] = [:]
        // Column-major 3×3 intrinsics: fx c0r0, fy c1r1, cx c2r0, cy c2r1.
        if capture.cameraIntrinsics.count >= 9 {
            metadata["fx"] = capture.cameraIntrinsics[0]
            metadata["fy"] = capture.cameraIntrinsics[4]
            metadata["cx"] = capture.cameraIntrinsics[6]
            metadata["cy"] = capture.cameraIntrinsics[7]
        }
        if capture.cameraImageResolution.count >= 2 {
            metadata["width"] = capture.cameraImageResolution[0]
            metadata["height"] = capture.cameraImageResolution[1]
        }
        return metadata
    }
}
