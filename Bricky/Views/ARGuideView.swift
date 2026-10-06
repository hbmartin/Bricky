import ARKit
import BrickyLanguage
import RealityKit
import RecoveryMLX
import SwiftUI

struct ARGuideView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(BuildSessionController.self) private var session
    @EnvironmentObject private var partPack: LDrawPartPackManager
    @EnvironmentObject private var recoveryModel: RecoveryModelManager
    let model: StoredInstructionModel
    let plan: InstructionPlan
    @State private var step: AuthoredStep
    @StateObject private var camera = ARCameraManager()
    @StateObject private var alignment = ARAlignmentController()
    @StateObject private var registration = RegistrationController()
    @StateObject private var verification = StepVerificationController()
    @State private var entity: Entity?
    @State private var error: String?
    @State private var isAdvancing = false
    @StateObject private var photoCheck = PhotoCheckController()
    @AppStorage(AppConfig.Defaults.evidenceCaptureEnabled) private var evidenceCaptureEnabled = false
    @AppStorage(AppConfig.Defaults.corpusCollectionEnabled) private var corpusCollectionEnabled = false
    @AppStorage(AppConfig.Defaults.suggestedPlacementEnabled) private var suggestedPlacementEnabled = false
    @AppStorage(AppConfig.Defaults.handsFreeEnabled) private var handsFreeEnabled = false
    @AppStorage(AppConfig.Defaults.languageModelWordingEnabled) private var languageModelWordingEnabled = false
    /// Hands-free mode (ADR 0016): spoken steps and repairs, and "next",
    /// "next anyway", "back" and "repeat" by voice.
    @StateObject private var narrator = StepNarrator()
    @StateObject private var voice = VoiceCommandService()
    /// What is built before this step, for fitting a suggested ghost.
    @State private var builtSnapshot: InstructionGeometrySnapshot?
    @State private var stagedDeclaration: StagedFixtureDeclaration?
    @State private var showStagedSetup = false
    /// The open evidence session for the current photo check, and the
    /// declaration it was opened with.
    @State private var photoCheckRecorder: RecoveryEvidenceRecorder?
    @State private var photoCheckStaged: StagedFixtureDeclaration?
    @State private var photoCheckStep: AuthoredStep?
    @State private var photoCheckTask: Task<Void, Never>?
    /// Verification evidence for this AR visit (ADR 0007 amendment 2):
    /// exists only while evidence capture is on.
    @State private var verificationRecorder: RecoveryEvidenceRecorder?
    @State private var stagedVerification: StagedVerificationDeclaration?
    @State private var showStagedVerificationSetup = false
    /// The current step's parts in sentence form ("red Brick 2 x 4"), by
    /// placement index, for repair wording.
    @State private var partLabels: [Int: String] = [:]
    @State private var directionStabilizer = DirectionStabilizer()
    /// What to do about a misplaced step, worded from the poses (ADR 0015).
    @State private var repairLine: String?
    /// Template first, then the language layer's validated sentence (ADR
    /// 0017). Built when the guide opens; nil wording means templates only.
    @State private var wording: RepairWordingCoordinator?

    init(model: StoredInstructionModel, plan: InstructionPlan, step: AuthoredStep) {
        self.model = model
        self.plan = plan
        _step = State(initialValue: step)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ARInstructionOverlay(
                    session: camera.session,
                    entity: entity,
                    alignment: alignment.alignment,
                    trackedTransform: registration.trackedTransform,
                    isLocked: registration.registration?.state == .locked,
                    suggestedTransform: alignment.suggestion?.worldFromModel
                )
                .ignoresSafeArea()
                Image(systemName: "plus").font(.title).foregroundStyle(.white).shadow(radius: 3)
                VStack {
                    HStack {
                        Text(alignment.guidance).font(.callout.weight(.semibold))
                        Spacer()
                        if let status = registration.statusLabel {
                            Text(status)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(
                                    registration.registration?.state == .locked
                                        ? Color.green.opacity(0.25)
                                        : Color.orange.opacity(0.25),
                                    in: Capsule()
                                )
                        }
                        Button("Reset") { alignment.reset() }
                    }
                    .padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14)).padding()
                    if let verdictLabel = repairLine ?? verification.statusLabel {
                        HStack(spacing: 6) {
                            Image(systemName: verification.isComplete ? "checkmark.circle.fill" : (repairLine == nil ? "eye" : "arrow.uturn.backward"))
                            Text(verdictLabel)
                        }
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(verification.isComplete ? .green : .primary)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .accessibilityLabel("Step verification: \(verdictLabel). This check is advisory; you decide when to advance.")
                    }
                    if handsFreeEnabled {
                        VoiceStatusChip(state: voice.state, speaking: narrator.isSpeaking)
                    }
                    if evidenceCaptureEnabled, corpusCollectionEnabled {
                        Button {
                            showStagedVerificationSetup = true
                        } label: {
                            Label(
                                stagedVerification.map { "Staged: \($0.scenario.rawValue)" } ?? "Stage This Step",
                                systemImage: "tag"
                            )
                        }
                        .buttonStyle(.bordered)
                        .font(.caption)
                    }
                    Spacer()
                    photoCheckSection
                    if verification.isStablyComplete, photoCheck.state == .idle {
                        // One tap after ≥2 s of stable complete — the user
                        // still confirms; nothing auto-advances (ADR 0008).
                        Button(
                            step.index < plan.steps.count ? "Confirm & Next" : "Confirm & Finish",
                            systemImage: "checkmark.circle.fill"
                        ) { confirmAndAdvance() }
                            .buttonStyle(.borderedProminent).tint(.green).controlSize(.large)
                            .padding(.bottom, 4)
                    }
                    if alignment.alignment == nil, alignment.suggestion != nil {
                        // A suggestion is only ever a proposal: registration
                        // starts from it only after this tap (ADR 0009).
                        HStack {
                            Button("Use Suggested Position") { alignment.acceptSuggestion() }
                                .buttonStyle(.borderedProminent)
                            Button("Place Manually") { alignment.declineSuggestion() }
                                .buttonStyle(.bordered)
                        }
                        .controlSize(.large)
                    } else if alignment.alignment == nil {
                        HStack {
                            if suggestedPlacementEnabled, let builtSnapshot {
                                Button("Suggest Position") {
                                    let viewport = Self.viewport(proxy)
                                    Task { await alignment.suggest(manager: camera, viewport: viewport, build: builtSnapshot) }
                                }
                                .buttonStyle(.bordered)
                                .disabled(alignment.isSuggesting)
                            }
                            Button("Place Ghost Here") { alignment.placeGhost(manager: camera, proxy: proxy) }
                                .buttonStyle(.borderedProminent)
                        }
                        .controlSize(.large)
                    } else {
                        AlignmentNudgePad(alignment: alignment)
                    }
                }
            }
            .task {
                camera.checkPermissions()
                startVerificationEvidence()
                startWording()
                registration.frameObserver = { [weak verification] frame, update in
                    verification?.submit(frame: frame, registration: update)
                }
                session.setAttending(scenePhase != .background, by: Self.attendanceID)
                startHandsFree()
                await loadEntity()
                // Placement can precede the fit sample when geometry loads
                // slowly; make sure tracking starts once both exist.
                registration.refit(alignment: alignment.alignment, relay: camera.registrationRelay)
            }
            .onDisappear {
                session.setAttending(false, by: Self.attendanceID)
                session.reportVerification(nil, repairSentence: nil)
                stopHandsFree()
                endPhotoCheck(confirmed: false)
                verification.recordWindow(trigger: .stepExit)
                endVerificationEvidence()
                verification.stop()
                Task { await PlacementGeometryStore.shared.purge() }
                registration.stop()
                camera.stopSession()
                // Re-entry re-runs the session with reset options, which
                // starts a new world frame; drop the stale ghost pose.
                alignment.reset()
            }
            .onChange(of: camera.trackingState) { _, state in
                if case .notAvailable = state, alignment.alignment != nil { alignment.trackingLost() }
            }
            .onChange(of: alignment.alignment) { _, newValue in
                registration.alignmentChanged(newValue, relay: camera.registrationRelay)
            }
            .onChange(of: session.cursorStep?.id) { _, _ in
                follow(session.cursorStep)
            }
            .onChange(of: verification.verification?.timestamp) { _, _ in
                updateRepairLine()
                session.reportVerification(verification.verification, repairSentence: repairLine)
            }
            .onChange(of: scenePhase) { _, phase in
                // Nobody confirms from the background (ADR 0016). Inactive
                // still counts as attended: Siri's own overlay makes the app
                // inactive. The microphone listens only while active.
                session.setAttending(phase != .background, by: Self.attendanceID)
                if phase == .active {
                    startHandsFree()
                } else {
                    stopHandsFree()
                }
            }
        }
        .navigationTitle("AR Step \(step.index)")
        .navigationBarTitleDisplayMode(.inline)
        .alert("AR Unavailable", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
        .sheet(isPresented: $showStagedSetup) {
            StagedFixtureSetupView(plan: plan, declaration: $stagedDeclaration)
        }
        .sheet(isPresented: $showStagedVerificationSetup) {
            StagedVerificationSetupView(declaration: $stagedVerification, stepIndex: step.index)
        }
        .onChange(of: stagedVerification) { _, declaration in
            verification.setStagedVerification(declaration)
        }
    }

    /// The VLM photo check at the locked pose: offered only while the
    /// registration is locked and the model is admitted, and advisory like
    /// every verdict here (ADR 0008).
    @ViewBuilder
    private var photoCheckSection: some View {
        switch photoCheck.state {
        case .idle:
            if registration.lockedAlignment != nil, recoveryModel.isVLMAdmitted {
                VStack(spacing: 6) {
                    if evidenceCaptureEnabled, corpusCollectionEnabled {
                        StagedDeclarationButton(declaration: stagedDeclaration) { showStagedSetup = true }
                    }
                    Button("Photo Check", systemImage: "camera.viewfinder") { startPhotoCheck() }
                        .buttonStyle(.bordered).controlSize(.large)
                }
                .padding(.bottom, 4)
            }
        case .checking:
            HStack(spacing: 8) {
                ProgressView()
                Text("Checking this step…")
                Button("Cancel") { endPhotoCheck(confirmed: false) }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.bottom, 4)
        case .finished(let result):
            VStack(spacing: 10) {
                Label("Photo check: \(result.rawValue.capitalized)", systemImage: photoCheckIcon(result))
                    .font(.headline)
                Text("This result is advisory. You decide when to advance.")
                    .font(.caption)
                HStack {
                    Button("Done") { endPhotoCheck(confirmed: false) }
                    if result == .complete {
                        Button(step.index < plan.steps.count ? "Confirm & Next" : "Confirm & Finish") {
                            confirmPhotoCheck()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18)).padding(.bottom, 4)
        case .failed(let message):
            VStack(spacing: 8) {
                Label("Photo check unavailable", systemImage: "exclamationmark.triangle").font(.headline)
                Text(message).font(.caption).multilineTextAlignment(.center)
                Button("Done") { endPhotoCheck(confirmed: false) }
            }
            .padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18)).padding(.bottom, 4)
        }
    }

    private func photoCheckIcon(_ result: StepCheckResult) -> String {
        switch result {
        case .complete: "checkmark.circle.fill"
        case .incomplete: "xmark.circle.fill"
        case .uncertain: "questionmark.circle.fill"
        }
    }

    private func startPhotoCheck() {
        guard let pack = partPack.readyLibraryURL, let modelDirectory = recoveryModel.modelDirectory else { return }
        guard InferencePolicy.decide(.check, thermal: ProcessInfo.processInfo.thermalState) != .deferred else {
            photoCheck.refuse(InferencePolicy.deferredCheckMessage)
            return
        }
        let staged = evidenceCaptureEnabled && corpusCollectionEnabled ? stagedDeclaration : nil
        let recorder = makePhotoCheckRecorder(staged: staged)
        let checkedStep = step
        let service: any StepCheckAdvisor = VLMStepCheckService(
            runtime: recoveryModel.runtime,
            modelDirectory: modelDirectory,
            partPackRoot: pack,
            variant: InferenceArmScheduler().next(evidenceEnabled: evidenceCaptureEnabled),
            recorder: recorder
        )
        let source = LivePoseSource(registration: registration, verification: verification)
        let task = photoCheck.start(source: source) { alignment in
            // The capture carries the locked alignment's identity: the
            // registered target is rendered from this photo's camera under
            // exactly that pose.
            let capture = try RecoveryCaptureService().capture(from: camera, angle: .center, alignmentID: alignment.id)
            // The AR guide keeps no milestone images; the recorder copies
            // the photo when evidence is on.
            let captureURL = try InstructionModelImporter.applicationSupportRoot()
                .appendingPathComponent(capture.imageRelativePath)
            defer { RecoveryWorkFileCleanup.remove(urls: [captureURL]) }
            return try await service.check(capture: capture, plan: plan, step: checkedStep, registered: alignment).result
        }
        guard let task else { return }
        photoCheckTask = task
        photoCheckRecorder = recorder
        photoCheckStaged = staged
        photoCheckStep = checkedStep
        // Registered so the app can cancel AND await in-flight MLX inference
        // before unloading the runtime on suspension.
        recoveryModel.trackInference(task)
    }

    /// A complete photo check confirmed by the user: a human label, and an
    /// advance through the shared session like every other confirm.
    private func confirmPhotoCheck() {
        guard !isAdvancing else { return }
        endPhotoCheck(confirmed: true)
        isAdvancing = true
        verification.recordWindow(trigger: .confirm)
        stagedVerification = nil
        verification.stop()
        session.confirm(step, source: .photoCheck)
        guard step.index < plan.steps.count else {
            dismiss()
            return
        }
        follow(session.cursorStep)
    }

    /// Ends the check however it ended: cancels a running one and labels
    /// its evidence (a staged declaration labels it either way) once the
    /// check has stopped writing to it.
    private func endPhotoCheck(confirmed: Bool) {
        var analysisError: String?
        if case .failed(let message) = photoCheck.state { analysisError = message }
        photoCheck.cancel()
        let task = photoCheckTask
        let recorder = photoCheckRecorder
        let groundTruth = photoCheckStep.map {
            VLMStepCheckService.groundTruth(staged: photoCheckStaged, plan: plan, step: $0, confirmed: confirmed)
        } ?? .unlabeled
        photoCheckTask = nil
        photoCheckRecorder = nil
        photoCheckStaged = nil
        photoCheckStep = nil
        guard let recorder else { return }
        Task.detached(priority: .utility) {
            await task?.value
            await recorder.finalize(estimate: nil, analysisError: analysisError, groundTruth: groundTruth)
        }
    }

    /// The full-window viewport the reticle is centred in, as placement uses.
    static func viewport(_ proxy: GeometryProxy) -> CGSize {
        CGSize(
            width: proxy.size.width + proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing,
            height: proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
        )
    }

    /// Words a repair for a misplaced step: which part, and which way from
    /// where the user stands once the direction holds steady. Text only; no
    /// arrow (ADR 0015).
    private func updateRepairLine() {
        guard let current = verification.verification, case .misplaced = current.verdict,
              let repair = RepairPlanner.plan(verdict: current.verdict, context: RepairPlanner.context(plan: plan, step: step)),
              let first = repair.actions.first else {
            repairLine = nil
            return
        }
        var direction: RelativeDirection?
        if case .move(_, let by) = first, let worldFromModel = current.worldFromModel, let worldFromCamera = current.worldFromCamera {
            direction = directionStabilizer.update(
                bearing: CameraRelativeDirection.bearingDegrees(
                    correction: CameraRelativeDirection.worldCorrection(by, worldFromModel: worldFromModel),
                    worldFromCamera: worldFromCamera,
                    rotation: ARCameraManager.screenRotation()
                ),
                pitchDegrees: CameraRelativeDirection.pitchDegrees(worldFromCamera: worldFromCamera),
                at: current.timestamp
            )
        }
        let template = RepairPhrasebook.sentence(for: repair.actions, direction: direction, labels: partLabels)
        guard let wording, let template,
              let facts = RepairWordingFacts(actions: repair.actions, direction: direction, labels: partLabels, template: template) else {
            repairLine = template
            return
        }
        repairLine = wording.update(facts) ?? template
    }

    /// The language layer for this visit, when the developer setting is on.
    /// A validated sentence that lands for the repair still on screen
    /// replaces the template there and in what Siri reads (ADR 0017).
    private func startWording() {
        guard wording == nil else { return }
        let coordinator = RepairWordingCoordinator(
            generator: RepairWordingSource.generator(enabled: languageModelWordingEnabled)
        )
        coordinator.onWorded = { sentence in
            repairLine = sentence
            session.reportVerification(verification.verification, repairSentence: sentence)
        }
        coordinator.onResult = { facts, result in
            guard let recorder = verificationRecorder else { return }
            let record = RepairWordingRecordV1(
                sessionID: recorder.sessionID, stepID: step.id, action: facts.action.rawValue,
                partLabel: facts.partLabel, partCount: facts.partCount, direction: facts.direction?.rawValue,
                studs: facts.studs, turn: facts.turn?.rawValue, template: facts.template,
                modelSentence: result.modelSentence, outcome: result.outcome.name,
                shown: result.sentence ?? facts.template, latencyMilliseconds: result.milliseconds,
                osBuild: DeviceIdentity.osBuild, deviceModel: DeviceIdentity.modelIdentifier, createdAt: .now
            )
            Task { await recorder.recordWording(record) }
        }
        wording = coordinator
    }

    /// The step's parts in sentence form, from the pack's descriptions.
    private func loadPartLabels(for step: AuthoredStep) async {
        guard let pack = partPack.readyLibraryURL, let index = PartDescriptionIndexCache.index(for: plan, partPackRoot: pack) else {
            partLabels = [:]
            return
        }
        var labels: [Int: String] = [:]
        let lower = min(max(0, step.addedPlacementRange.lowerBound), plan.placementTimeline.count)
        let upper = min(max(lower, step.addedPlacementRange.upperBound), plan.placementTimeline.count)
        for placementIndex in lower..<upper {
            let placement = plan.placementTimeline[placementIndex]
            let colour = PartNaming.colourName(code: placement.colorCode, definitionName: LDrawPalette.definition(placement.colorCode)?.name)
            labels[placementIndex] = PartNaming.inSentence(colour: colour, part: await index.description(for: placement.partReference))
        }
        partLabels = labels
    }

    /// With evidence on, records verification windows for this visit and
    /// asks the relay for the colour and occluder channels they keep. The
    /// colour term (M3.2) needs the colour plane even with evidence off
    /// (ADR 0007 amendment 3).
    private func startVerificationEvidence() {
        guard evidenceCaptureEnabled, verificationRecorder == nil,
              let recorder = makePhotoCheckRecorder(staged: nil) else {
            camera.registrationRelay.setAuxiliaryChannels(verification.colourTermMode == .off ? [] : [.colour])
            return
        }
        verificationRecorder = recorder
        verification.setWindowSink(recorder)
        camera.registrationRelay.setAuxiliaryChannels([.colour, .occluderMask])
    }

    private func endVerificationEvidence() {
        camera.registrationRelay.setAuxiliaryChannels([])
        verification.setWindowSink(nil)
        guard let recorder = verificationRecorder else { return }
        verificationRecorder = nil
        Task.detached(priority: .utility) {
            // Session metadata only: a verification visit carries its ground
            // truth on each window, not as a step count.
            guard await recorder.verificationWindowCount > 0 else { return }
            await recorder.finalize(estimate: nil, analysisError: nil, groundTruth: .unlabeled)
        }
    }

    private func makePhotoCheckRecorder(staged: StagedFixtureDeclaration?) -> RecoveryEvidenceRecorder? {
        guard evidenceCaptureEnabled, let root = try? InstructionModelImporter.applicationSupportRoot() else { return nil }
        return RecoveryEvidenceRecorder(
            root: root,
            instructionSHA256: plan.sourceSHA256,
            authoredModelID: model.id,
            modelTitle: model.title,
            stepCount: plan.steps.count,
            staged: staged,
            admission: recoveryModel.admissionSnapshot,
            conditions: DeviceConditionsProbe.snapshot()
        )
    }

    /// Confirms through the shared session; the cursor change then advances
    /// this AR session in place (`follow(_:)`).
    private func confirmAndAdvance() {
        guard !isAdvancing else { return }
        isAdvancing = true
        verification.recordWindow(trigger: .confirm)
        stagedVerification = nil
        // Dropping the verdict hides the confirm affordance immediately, so
        // one physical step cannot be confirmed twice before the next loads.
        verification.stop()
        session.confirm(step, source: .arVerified)
        guard step.index < plan.steps.count else {
            dismiss()
            return
        }
        follow(session.cursorStep)
    }

    /// Moves this AR session to `next` — after a confirm here, or when the
    /// cursor moved elsewhere (voice, Siri, another view): the next step's
    /// geometry loads, verification restarts on the new delta, and the
    /// tracker re-fits the grown build from its current pose.
    private func follow(_ next: AuthoredStep?) {
        guard let next, next.id != step.id else {
            isAdvancing = false
            return
        }
        // Moving on without a complete verdict is the user overriding the
        // verifier; after a confirm the window is already written. Browsing
        // back overrides nothing.
        verification.recordWindow(trigger: next.index > step.index && !verification.isComplete ? .override : .stepExit)
        stagedVerification = nil
        verification.stop()
        repairLine = nil
        wording?.reset()
        directionStabilizer = DirectionStabilizer()
        step = next
        Task {
            await loadEntity()
            registration.refit(alignment: alignment.alignment, relay: camera.registrationRelay)
            isAdvancing = false
        }
    }

    @MainActor
    private func loadEntity() async {
        guard let partPackRoot = partPack.readyLibraryURL else { error = "Install the LDraw part pack first."; return }
        do {
            let root = try InstructionModelImporter.applicationSupportRoot()
            let source = root.appendingPathComponent("Models/\(plan.sourceSHA256)/Source")
            // One flatten for the whole visit: each step's geometry is a
            // range of it (M2.0), identical to a per-step snapshot.
            let geometry = try await PlacementGeometryStore.shared.geometry(
                for: plan, sourceRoot: source, partPackRoot: partPackRoot
            )
            // Same completed/new treatment as the on-screen guide: dimmed
            // prior work under a full-opacity ghost of this step's additions.
            // Both stay solid translucent renders — never wireframe — per the
            // ADR 0008 design-around.
            let completed = plan.completedPlacements(before: step)
            let container = Entity()
            let stepGeometry = StepGeometry(step: step, geometry: geometry)
            let completedSnapshot = stepGeometry.completedSnapshot
            builtSnapshot = completedSnapshot.buffers.isEmpty ? nil : completedSnapshot
            if !completed.isEmpty {
                container.addChild(try RealityKitInstructionAdapter.makeEntity(from: completedSnapshot, dimmed: true))
                // The physical build at this point is the completed geometry;
                // that is what the depth tracker registers against.
                // The snapshot is the build through the *previous* step, so
                // the sample carries that step's index.
                registration.setFitSample(
                    ModelSurfaceSampler.sample(completedSnapshot, stepIndex: step.index - 1)
                )
            } else {
                registration.setFitSample(nil)
            }
            let additionSnapshot = stepGeometry.deltaSnapshot
            container.addChild(try RealityKitInstructionAdapter.makeEntity(from: additionSnapshot))
            entity = container
            await verification.begin(
                stepID: step.id,
                geometry: stepGeometry,
                stepIndex: step.index - 1
            )
            await loadPartLabels(for: step)
            announceStep()
        } catch { self.error = error.localizedDescription }
    }

    private static let attendanceID = "ar_guide"

    private func startHandsFree() {
        guard handsFreeEnabled, scenePhase == .active else { return }
        narrator.onSpeakingChanged = { [weak voice] speaking in
            if speaking {
                voice?.narrationStarted()
            } else {
                voice?.narrationEnded()
            }
        }
        voice.onCommand = { command in handle(command) }
        Task { await voice.start() }
    }

    private func stopHandsFree() {
        voice.stop()
        narrator.stop()
    }

    /// Says which step is on screen and what it adds.
    private func announceStep() {
        guard handsFreeEnabled, scenePhase == .active else { return }
        narrator.speak(StepNarration.announcement(
            stepNumber: step.index,
            stepCount: plan.steps.count,
            partLabels: partLabels.sorted { $0.key < $1.key }.map(\.value)
        ))
    }

    /// A voice command, through the same session policy Siri uses
    /// (ADR 0016). Advancing and browsing move the cursor; `follow(_:)`
    /// then loads and announces the step.
    private func handle(_ command: VoiceCommand) {
        switch command {
        case .next, .nextAnyway:
            guard !isAdvancing else { return }
            let decision = session.requestAdvance(
                command == .next ? .next : .nextAnyway, source: .voice, verification: verification.verification
            )
            switch decision {
            case .advance, .browseForward:
                if session.cursorStep?.id != step.id {
                    isAdvancing = true
                } else if session.isFinished {
                    narrator.speak(StepNarration.buildFinished)
                } else {
                    announceStep()
                }
            case .holdAndSpeak(let repair):
                // The line on screen, so narration and Siri say what the
                // user sees, including a validated model sentence.
                let sentence = repair == nil ? nil : repairLine ?? repair.flatMap {
                    RepairPhrasebook.sentence(for: $0.actions, direction: directionStabilizer.current, labels: partLabels)
                }
                narrator.speak(StepNarration.hold(repairSentence: sentence))
            case .refuse(let reason):
                narrator.speak(StepNarration.refusal(reason))
            }
        case .back:
            guard !isAdvancing else { return }
            if session.cursorIndex == 0 {
                announceStep()
            } else {
                session.browse(by: -1)
            }
        case .repeatLast:
            narrator.repeatLast()
        }
    }
}

/// Whether hands-free mode is listening, speaking, or why it cannot.
private struct VoiceStatusChip: View {
    let state: VoiceCommandService.State
    let speaking: Bool

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .preparing:
            Label("Preparing voice commands…", systemImage: "mic")
                .modifier(ChipStyle())
        case .listening:
            Label(
                speaking ? "Speaking" : "Listening for “next”",
                systemImage: speaking ? "speaker.wave.2" : "mic.fill"
            )
            .modifier(ChipStyle())
        case .unavailable(let reason):
            Label(reason, systemImage: "mic.slash")
                .modifier(ChipStyle())
        }
    }

    private struct ChipStyle: ViewModifier {
        func body(content: Content) -> some View {
            content
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }
}

/// The AR guide's registration and verifier, as a photo check sees them.
@MainActor
private struct LivePoseSource: RegisteredPoseSource {
    let registration: RegistrationController
    let verification: StepVerificationController

    var lockedAlignment: ARAlignment? { registration.lockedAlignment }
    func suspendVerification() { verification.suspend() }
    func resumeVerification() { verification.resume() }
}

private struct AlignmentNudgePad: View {
    @ObservedObject var alignment: ARAlignmentController
    private let nudge: Float = 0.002

    var body: some View {
        VStack(spacing: 8) {
            Button { alignment.nudge(z: -nudge) } label: { Image(systemName: "arrow.up") }
                .accessibilityLabel("Move ghost forward")
            HStack(spacing: 12) {
                Button { alignment.nudge(x: -nudge) } label: { Image(systemName: "arrow.left") }
                    .accessibilityLabel("Move ghost left")
                Button { alignment.nudge(yawDegrees: -1) } label: { Image(systemName: "rotate.left") }
                    .accessibilityLabel("Rotate ghost left")
                Button { alignment.nudge(yawDegrees: 1) } label: { Image(systemName: "rotate.right") }
                    .accessibilityLabel("Rotate ghost right")
                Button { alignment.nudge(x: nudge) } label: { Image(systemName: "arrow.right") }
                    .accessibilityLabel("Move ghost right")
            }
            Button { alignment.nudge(z: nudge) } label: { Image(systemName: "arrow.down") }
                .accessibilityLabel("Move ghost backward")
        }
        .buttonStyle(.borderedProminent)
        .padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18)).padding(.bottom)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Fine alignment controls, two millimeter translation and one degree rotation")
    }
}
