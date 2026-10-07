import Foundation
import OSLog
import SwiftUI

/// Drives live geometric verification for the step being built. Frames and
/// registrations arrive through `RegistrationController.frameObserver`; the
/// verifier only ever judges under a locked registration, and its output is
/// advisory (ADR 0008) — the user confirms every step.
///
/// Verification runs beside tracking, never inside it: `submit` keeps only
/// the newest frame and returns at once, and a single worker drains it. A
/// frame that arrives while the verifier is busy replaces the waiting one
/// instead of queueing, so a slow render costs verification frames, not
/// tracking frames.
@MainActor
final class StepVerificationController: ObservableObject {
    @Published private(set) var verification: StepVerification?
    /// True once the verdict has been continuously complete for
    /// `stableCompleteInterval` — the gate for the one-tap Confirm & Next
    /// affordance. Never auto-advances (ADR 0008).
    @Published private(set) var isStablyComplete = false
    /// Set when the geometric verifier cannot be constructed (no Metal);
    /// surfaced so the guide can explain the missing check.
    @Published private(set) var unavailableReason: String?
    /// True while a photo check runs the VLM: the verifier's renders would
    /// share the GPU with inference, so it pauses instead (ADR 0003).
    @Published private(set) var isSuspended = false

    private let makeVerifier: () throws -> any StepJudging
    private var verifier: (any StepJudging)?
    /// The colour term's latest reading when the verifier carries it
    /// (M3.2). Logged and recorded in evidence windows; never shown.
    private(set) var lastColourAssessment: ColourAssessment?
    /// The mode the current verifier was built with.
    private(set) var colourTermMode: ColourTermMode = .off
    /// The build diff in shadow (M2.3): judges the same frames after the
    /// verifier, only while evidence capture is on, and is never published.
    private let makeShadow: () throws -> any ShadowStepJudging
    private let shadowEnabled: () -> Bool
    private var shadow: (any ShadowStepJudging)?
    /// The shadow's latest diff and its placement-aware verdict, for logs
    /// and evidence windows. Deliberately not `@Published`.
    private(set) var lastShadowDiff: BuildDiff?
    private(set) var lastShadowVerdict: StepVerification?
    private let logger = Logger(subsystem: AppConfig.bundleID, category: "BuildDiff")
    /// Bumped on every `begin` and `stop`: a frame in flight across the step
    /// boundary must not publish into the new step's verification.
    private var generation = 0
    /// False while `begin` installs a step: a frame judged before the
    /// verifier holds the new geometry would be judged against the old.
    private var acceptingFrames = false
    private var pending: (frame: RegistrationFrameInput, registration: ModelRegistration)?
    private var worker: Task<Void, Never>?
    private var completeSince: TimeInterval?
    private let stableCompleteInterval: TimeInterval = 2.0
    private var lastIngestTimestamp: TimeInterval = -.infinity
    /// The verifier renders several expected-depth maps per ingest; feeding
    /// it slower than the relay rate loses nothing at a 20–40 frame
    /// evidence budget.
    private let minimumInterval: TimeInterval = 0.2

    // Evidence windows (ADR 0007 amendment 2): only while a sink is set.
    private var windowSink: (any VerificationWindowSink)?
    private var windowBuffer = VerificationWindowBuffer(capacity: 8)
    private var stepID = ""
    private var stepIndex = 0
    private var stagedVerification: StagedVerificationDeclaration?
    private var lastVerdictKind: String?
    private var lastWindowAt: TimeInterval = -.infinity
    private var ingestMillisecondsSinceBegin = 0
    /// Verdict-change windows closer together than this would mostly
    /// repeat the same frames.
    private let windowSpacing: TimeInterval = 3

    init(
        makeVerifier: (() throws -> any StepJudging)? = nil,
        makeShadow: (() throws -> any ShadowStepJudging)? = nil,
        shadowEnabled: @escaping () -> Bool = {
            UserDefaults.standard.bool(forKey: AppConfig.Defaults.evidenceCaptureEnabled)
        },
        colourTermMode: @escaping () -> ColourTermMode = { StepVerificationController.storedColourTermMode() },
        colourTable: @escaping @MainActor () -> ColourTable = { ColourTable(definitions: LDrawPalette.installedDefinitions) }
    ) {
        // The colour term (M3.2) is read once, when the AR guide opens: a
        // verifier keeps its mode for the visit.
        let mode = colourTermMode()
        self.colourTermMode = mode
        if let makeVerifier {
            self.makeVerifier = makeVerifier
        } else {
            self.makeVerifier = {
                guard mode != .off else { return try GeometricStepVerifier() }
                return try ColourTermJudge(mode: mode, table: MainActor.assumeIsolated { colourTable() })
            }
        }
        if let makeShadow {
            self.makeShadow = makeShadow
        } else {
            self.makeShadow = {
                var configuration = BuildDiffEngine.Configuration()
                // The shadow diff reads colour per placement whenever the
                // term is on at all.
                if mode != .off { configuration.colourTable = MainActor.assumeIsolated { colourTable() } }
                return try BuildDiffEngine(configuration: configuration, policy: .placementAware)
            }
        }
        self.shadowEnabled = shadowEnabled
    }

    /// The developer setting, with Full (replay-only until ADR 0008's
    /// amendment is accepted) held at Block only.
    nonisolated static func storedColourTermMode(_ defaults: UserDefaults = .standard) -> ColourTermMode {
        let stored = ColourTermMode(rawValue: defaults.string(forKey: AppConfig.Defaults.colourTermMode) ?? "") ?? .off
        return stored == .full ? .blockOnly : stored
    }

    var statusLabel: String? {
        guard let verification else { return unavailableReason }
        switch verification.verdict {
        case .complete:
            return String(localized: "Step looks complete")
        case .incomplete:
            return String(localized: "Step not complete yet")
        case .misplaced:
            // Which way to move is a repair sentence (RepairPhrasebook),
            // worded from the poses; this is the fallback when the guide has
            // no repair to show.
            return String(localized: "This step's parts look shifted")
        case .uncertain(let reason):
            switch reason {
            case .registrationNotLocked, .poseAmbiguous:
                return nil
            case .deltaUndetectable:
                return String(localized: "Parts too small to verify by depth")
            case .occludedView:
                return String(localized: "Move to see this step's parts")
            case .insufficientEvidence:
                return String(localized: "Checking…")
            }
        }
    }

    var isComplete: Bool { verification?.verdict.isComplete == true }

    func begin(
        stepID: String,
        completedSnapshot: InstructionGeometrySnapshot,
        deltaSnapshot: InstructionGeometrySnapshot,
        stepIndex: Int = 0
    ) async {
        await begin(
            stepID: stepID,
            geometry: StepGeometry(completedSnapshot: completedSnapshot, deltaSnapshot: deltaSnapshot),
            stepIndex: stepIndex
        )
    }

    func begin(stepID: String, geometry: StepGeometry, stepIndex: Int = 0) async {
        generation += 1
        let beginGeneration = generation
        acceptingFrames = false
        pending = nil
        verification = nil
        isStablyComplete = false
        completeSince = nil
        lastIngestTimestamp = -.infinity
        self.stepID = stepID
        self.stepIndex = stepIndex
        resetWindow()
        do {
            let verifier = try verifier ?? makeVerifier()
            self.verifier = verifier
            unavailableReason = nil
            // Awaited, with frames refused until it returns, so no frame can
            // reach the verifier before it holds this step's snapshots.
            await verifier.begin(stepID: stepID, geometry: geometry)
            lastShadowDiff = nil
            lastShadowVerdict = nil
            lastColourAssessment = nil
            if shadowEnabled(), let judge = try? shadow ?? makeShadow() {
                shadow = judge
                await judge.begin(stepID: stepID, geometry: geometry)
            } else {
                shadow = nil
            }
            // A later begin() or stop() owns the state now.
            if beginGeneration == generation {
                acceptingFrames = true
            }
        } catch {
            verifier = nil
            unavailableReason = "Depth verification is unavailable: \(error.localizedDescription)"
        }
    }

    /// Tap point for `RegistrationController.frameObserver`. Returns
    /// immediately: the frame replaces any frame still waiting, and the
    /// worker judges it when the verifier is free.
    func submit(frame: RegistrationFrameInput, registration: ModelRegistration) {
        guard verifier != nil, acceptingFrames, !isSuspended else { return }
        guard frame.timestamp - lastIngestTimestamp >= minimumInterval else { return }
        lastIngestTimestamp = frame.timestamp
        pending = (frame, registration)
        if worker == nil {
            worker = Task { [weak self] in await self?.drain() }
        }
    }

    private func drain() async {
        while let next = pending, let verifier, acceptingFrames, !isSuspended {
            pending = nil
            let ingestGeneration = generation
            let started = ContinuousClock.now
            let result = try? await verifier.ingest(frame: next.frame, registration: next.registration)
            // A begin() or stop() while this ingest was in flight makes the
            // result stale; a suspension means the user is looking at a
            // photo check, and stability must be re-earned after it.
            guard let result, ingestGeneration == generation, !isSuspended else { continue }
            let elapsed = started.duration(to: .now).components
            let milliseconds = Int(elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000)
            ingestMillisecondsSinceBegin += milliseconds
            if windowSink != nil {
                windowBuffer.append(VerificationWindowSample(
                    frameID: UUID(), frame: next.frame, registration: next.registration,
                    result: result, ingestMilliseconds: milliseconds
                ))
            }
            publish(result, at: next.frame.timestamp)
            await readColourTerm(generation: ingestGeneration)
            await judgeInShadow(next.frame, next.registration, authoritative: result, generation: ingestGeneration)
        }
        worker = nil
    }

    /// Keeps the colour term's latest reading (M3.2) for logs and evidence
    /// windows. Read after the verdict is published, so it never delays it.
    private func readColourTerm(generation ingestGeneration: Int) async {
        guard let judge = verifier as? ColourTermJudge else { return }
        let assessment = await judge.lastAssessment
        guard ingestGeneration == generation else { return }
        if case .disagrees(let nearest) = assessment?.status, lastColourAssessment?.status != assessment?.status {
            logger.notice("Colour term (\(self.colourTermMode.rawValue, privacy: .public)) disagrees: nearest colour \(nearest, privacy: .public)")
        }
        lastColourAssessment = assessment
    }

    /// Runs the shadow on the frame the verifier just judged. Its errors are
    /// ignored and its verdict is only logged: the shadow can never change
    /// what the user sees.
    private func judgeInShadow(
        _ frame: RegistrationFrameInput, _ registration: ModelRegistration,
        authoritative: StepVerification, generation ingestGeneration: Int
    ) async {
        guard let shadow, ingestGeneration == generation, !isSuspended else { return }
        guard let verdict = try? await shadow.ingest(frame: frame, registration: registration),
              ingestGeneration == generation, !isSuspended else { return }
        lastShadowVerdict = verdict
        lastShadowDiff = await shadow.latestDiff()
        if verdict.verdict != authoritative.verdict {
            logger.notice("Shadow diff disagrees: verifier \(authoritative.verdict.evidenceName, privacy: .public), placement-aware \(verdict.verdict.evidenceName, privacy: .public)")
        }
    }

    private func publish(_ result: StepVerification, at timestamp: TimeInterval) {
        verification = result
        let kind = result.verdict.evidenceName
        if let previous = lastVerdictKind, previous != kind, timestamp - lastWindowAt >= windowSpacing {
            lastWindowAt = timestamp
            recordWindow(trigger: .verdictChange)
        }
        lastVerdictKind = kind
        if result.verdict.isComplete {
            let since = completeSince ?? timestamp
            completeSince = since
            isStablyComplete = timestamp - since >= stableCompleteInterval
        } else {
            completeSince = nil
            isStablyComplete = false
        }
    }

    /// Pauses verification for the length of a photo check. The current
    /// verdict stays on screen, but the one-tap confirm does not: it needs
    /// a fresh stable-complete interval after `resume()`. Independent of
    /// `begin`/`stop`, so a step change during the check stays paused.
    func suspend() {
        isSuspended = true
        pending = nil
        isStablyComplete = false
        completeSince = nil
    }

    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        lastIngestTimestamp = -.infinity
    }

    /// Starts or stops evidence windows. Off unless evidence capture is on.
    func setWindowSink(_ sink: (any VerificationWindowSink)?) {
        windowSink = sink
        if sink == nil { windowBuffer.removeAll() }
    }

    /// The declared physical state of the step being verified, or nil.
    func setStagedVerification(_ declaration: StagedVerificationDeclaration?) {
        stagedVerification = declaration
    }

    /// Sends the buffered frames and the current verdict to the sink. A
    /// no-op without a sink, a verdict, or frames: there is nothing to keep.
    func recordWindow(trigger: VerificationWindowRecord.Trigger) {
        guard let windowSink, let verification, !windowBuffer.samples.isEmpty else { return }
        let capture = VerificationWindowCapture(
            windowID: UUID(),
            stepID: stepID,
            stepIndex: stepIndex,
            trigger: trigger,
            samples: windowBuffer.samples,
            verification: verification,
            staged: stagedVerification,
            ingestMillisecondsSinceBegin: ingestMillisecondsSinceBegin,
            createdAt: .now,
            shadowDiff: lastShadowDiff,
            shadowVerdict: lastShadowVerdict,
            colourTermMode: colourTermMode == .off ? nil : colourTermMode,
            colourAssessment: lastColourAssessment
        )
        Task { await windowSink.record(capture) }
    }

    private func resetWindow() {
        windowBuffer.removeAll()
        lastVerdictKind = nil
        lastWindowAt = -.infinity
        ingestMillisecondsSinceBegin = 0
    }

    func stop() {
        // Invalidates any in-flight ingest first, so a result landing after
        // this stop cannot repopulate the cleared verification.
        generation += 1
        acceptingFrames = false
        pending = nil
        verification = nil
        isStablyComplete = false
        completeSince = nil
        lastIngestTimestamp = -.infinity
        resetWindow()
        lastShadowDiff = nil
        lastShadowVerdict = nil
        lastColourAssessment = nil
        if let verifier {
            Task { await verifier.resetEvidence() }
        }
        if let shadow {
            Task { await shadow.resetEvidence() }
        }
    }
}
