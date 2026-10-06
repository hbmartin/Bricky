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
    /// Which judge replays the windows: the verifier the device ran, or the
    /// build diff with its placement-aware verdict (M2.3).
    enum Judge: String {
        case verifier
        case diff
    }

    struct Summary {
        var windows = 0
        var replayed = 0
        var matches = 0
        var skippedSessions = 0
    }

    static func run(
        bundle: URL, plan: InstructionPlan, sourceIdentity: String, geometry: PlacementGeometry,
        renderer: ExpectedDepthRenderer, judge: Judge = .verifier,
        colourTerm: ColourTermMode? = nil, colourTable: ColourTable? = nil
    ) async throws -> (rows: [String], summary: Summary) {
        // Off is the depth-only judge, as a run without the flag.
        let colourMode = colourTerm == .off ? nil : colourTerm
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
                let verifier: any StepJudging
                switch (judge, colourMode, colourTable) {
                case (.verifier, let mode?, let table?):
                    verifier = try ColourTermJudge(mode: mode, table: table, renderer: renderer)
                case (.diff, _?, let table?):
                    var configuration = BuildDiffEngine.Configuration()
                    configuration.colourTable = table
                    verifier = try BuildDiffEngine(configuration: configuration, renderer: renderer, policy: .placementAware)
                case (.verifier, _, _):
                    verifier = try GeometricStepVerifier(renderer: renderer)
                case (.diff, _, _):
                    verifier = try BuildDiffEngine(renderer: renderer, policy: .placementAware)
                }
                await verifier.begin(stepID: step.id, geometry: StepGeometry(step: step, geometry: geometry))
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
                if let diff = verifier as? BuildDiffEngine, let placements = await diff.lastDiff?.observations {
                    print("window \(window.windowID.uuidString.prefix(8)): " + placements.map { "p\($0.placement)=\($0.state.name)" }.joined(separator: " "))
                }
                let colour = await (verifier as? ColourTermJudge)?.lastAssessment
                if let colour {
                    print("window \(window.windowID.uuidString.prefix(8)): colour \(colour.status.name), \(colour.framesCalibrated)/\(colour.framesWithColour) frames calibrated")
                }
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
                    matchesDevice: matches,
                    colourTermMode: colourMode?.rawValue,
                    colourStatus: colour?.status.name,
                    colourNearestCode: colour.flatMap { assessment in
                        if case .disagrees(let nearest) = assessment.status { return nearest }
                        return nil
                    }
                )
                rows.append(String(decoding: try encoder.encode(row), as: UTF8.self))
            }
        }
        return (rows, summary)
    }
}
