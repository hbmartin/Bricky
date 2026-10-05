import Foundation
import simd

/// Replays a bundle's verification evidence windows through the app's
/// verifier on a Mac (ADR 0007 amendment 2). Each window's frames are fed,
/// in order, to a fresh `GeometricStepVerifier` under the registration the
/// device recorded; the verdict after the last frame is compared with the
/// one the device published.
///
/// A fresh verifier sees only the window, while the device's had been
/// accumulating since the step began (`frames_used` on the window), so a
/// mismatch is not by itself a defect. Staged windows become `verification`
/// rows (provenance `replay`, never release evidence); every window counts
/// toward the printed agreement.
enum WindowReplay {
    struct Summary {
        var windows = 0
        var replayed = 0
        var matches = 0
        var skippedSessions = 0
    }

    static func run(
        bundle: URL, plan: InstructionPlan, sourceIdentity: String, engine: LDrawGeometryEngine,
        renderer: ExpectedDepthRenderer
    ) async throws -> (rows: [String], summary: Summary) {
        let reader = try EvidenceBundleReader(bundleDirectory: bundle)
        let issues = reader.validate()
        guard issues.isEmpty else {
            throw CLIError("invalid bundle:\n" + issues.joined(separator: "\n"))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var rows: [String] = []
        var summary = Summary()
        let steps = Dictionary(uniqueKeysWithValues: plan.steps.map { ($0.id, $0) })
        for session in try reader.loadSessions() where !session.verificationWindows.isEmpty {
            guard session.file.instructionSHA256 == sourceIdentity else {
                print("session \(session.file.sessionID.uuidString.prefix(8)): instruction \(session.file.instructionSHA256.prefix(12))… is not this model (\(sourceIdentity.prefix(12))…); skipped")
                summary.skippedSessions += 1
                continue
            }
            for window in session.verificationWindows {
                summary.windows += 1
                guard let step = steps[window.stepID] else {
                    print("window \(window.windowID.uuidString.prefix(8)): step \(window.stepID) is not in this plan; skipped")
                    continue
                }
                let completed = try await engine.snapshot(placements: Array(plan.completedPlacements(before: step)))
                let delta = try await engine.snapshot(placements: Array(plan.addedPlacements(for: step)))
                let verifier = try GeometricStepVerifier(renderer: renderer)
                await verifier.begin(stepID: step.id, completedSnapshot: completed, deltaSnapshot: delta)
                let started = ContinuousClock.now
                var result: StepVerification?
                for frame in window.frames {
                    guard let record = session.windowFrames[frame.frameID] else { continue }
                    let planes = try EvidenceDepthPlanes.load(record, in: session.directory)
                    result = try await verifier.ingest(
                        frame: RegistrationFrameInput(record: record, planes: planes),
                        registration: ModelRegistration(windowFrame: frame, stepIndex: window.stepIndex, timestamp: record.timestamp)
                    )
                }
                guard let result else { continue }
                summary.replayed += 1
                let produced = result.verdict.evidenceName
                let matches = produced == window.verdict
                summary.matches += matches ? 1 : 0
                guard let staged = window.staged else { continue }
                let elapsed = started.duration(to: .now).components
                let row = VerificationRowV1(
                    provenance: "replay",
                    fixtureID: window.windowID.uuidString,
                    expectedVerdict: staged.expectedVerdict,
                    producedVerdict: produced,
                    detectability: result.detectability.rawValue,
                    latencyMilliseconds: Int(elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000),
                    latencyScope: "replay_verifier_window",
                    deviceModel: "replay:\(DeviceIdentity.modelIdentifier)",
                    authoredModelID: session.file.authoredModelID.uuidString,
                    stepIndex: window.stepIndex,
                    deltaPixels: result.deltaPixels,
                    framesUsed: result.framesUsed,
                    windowTrigger: window.trigger.rawValue,
                    staged: staged,
                    deviceVerdict: window.verdict,
                    matchesDevice: matches
                )
                rows.append(String(decoding: try encoder.encode(row), as: UTF8.self))
            }
        }
        return (rows, summary)
    }
}
