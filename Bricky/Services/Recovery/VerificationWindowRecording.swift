import Foundation

/// Verification evidence windows (ADR 0007 amendment 2): the AR guide's
/// recorder keeps what the verifier saw around each verdict change, confirm,
/// override, and step exit, so verdicts can be replayed on a Mac and, with a
/// staged declaration, scored as device verification rows.
extension RecoveryEvidenceRecorder: VerificationWindowSink {
    func record(_ window: VerificationWindowCapture) async {
        let freeBytes = Self.availableBytes(at: sessionDirectory.deletingLastPathComponent())
        perform("record verification window") {
            guard windowBudgetAllows(freeBytes: freeBytes) else { return }
            try ensureStarted()
            try FileManager.default.createDirectory(
                at: sessionDirectory.appendingPathComponent("windows/frames", isDirectory: true),
                withIntermediateDirectories: true
            )
            for sample in window.samples where !hasWrittenWindowFrame(sample.frameID) {
                try writeDepthFrame(sample.frame, id: sample.frameID, stem: "windows/frames/\(sample.frameID.uuidString)")
                markWindowFrameWritten(sample.frameID)
            }
            let verification = window.verification
            let record = VerificationWindowRecord(
                windowID: window.windowID,
                sessionID: sessionID,
                stepID: window.stepID,
                stepIndex: window.stepIndex,
                trigger: window.trigger,
                createdAt: window.createdAt,
                frames: window.samples.map { sample in
                    VerificationWindowFrame(
                        frameID: sample.frameID,
                        registrationState: sample.registration.state.rawValue,
                        worldFromModel: sample.registration.worldFromModel.rowMajorValues,
                        rmsResidual: sample.registration.quality.rmsResidual,
                        inlierFraction: sample.registration.quality.inlierFraction,
                        latticeMargin: sample.registration.quality.latticeMargin,
                        verdictAfter: sample.result.verdict.evidenceName,
                        ingestMilliseconds: sample.ingestMilliseconds
                    )
                },
                verdict: verification.verdict.evidenceName,
                offsetStuds: verification.verdict.offsetStuds.map { [$0.x, $0.y] },
                uncertainReason: verification.verdict.uncertainReason?.rawValue,
                detectability: verification.detectability.rawValue,
                deltaPixels: verification.deltaPixels,
                framesUsed: verification.framesUsed,
                completeFraction: verification.completeFraction,
                incompleteFraction: verification.incompleteFraction,
                staged: window.staged
            )
            try EvidenceSchema.encoder(prettyPrinted: true).encode(record)
                .write(to: sessionDirectory.appendingPathComponent("windows/\(window.windowID.uuidString).json"), options: .atomic)
            noteWindowWritten()
            // A staged declaration closes when the user confirms, overrides,
            // or leaves the step: that closing window is the device row.
            if let staged = window.staged, window.trigger != .verdictChange {
                let row = VerificationRowV1(
                    provenance: "device",
                    fixtureID: window.windowID.uuidString,
                    expectedVerdict: staged.expectedVerdict,
                    producedVerdict: verification.verdict.evidenceName,
                    detectability: verification.detectability.rawValue,
                    latencyMilliseconds: window.ingestMillisecondsSinceBegin,
                    latencyScope: "verifier_compute_since_step_begin",
                    deviceModel: session.deviceModel,
                    authoredModelID: session.authoredModelID.uuidString,
                    stepIndex: window.stepIndex,
                    deltaPixels: verification.deltaPixels,
                    framesUsed: verification.framesUsed,
                    windowTrigger: window.trigger.rawValue,
                    staged: staged
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                var line = try encoder.encode(row)
                line.append(UInt8(ascii: "\n"))
                try append(line, to: Self.verificationRowsFilename)
            }
        }
    }

    /// Windows written to this session so far.
    var verificationWindowCount: Int { windowsWrittenCount }

    private func windowBudgetAllows(freeBytes: Int64?) -> Bool {
        guard windowsWrittenCount < Self.maxWindowsPerSession else { return false }
        if let freeBytes, freeBytes < Self.minimumFreeBytesForWindows { return false }
        return true
    }

    private static func availableBytes(at url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }
}

extension StepVerdict {
    var offsetStuds: SIMD2<Int>? {
        if case .misplaced(let offset) = self { return offset }
        return nil
    }

    var uncertainReason: UncertainReason? {
        if case .uncertain(let reason) = self { return reason }
        return nil
    }
}
