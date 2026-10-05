import ARKit
import RealityKit
import RecoveryMLX
import SwiftUI

struct ARGuideView: View {
    @Environment(\.dismiss) private var dismiss
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
                    isLocked: registration.registration?.state == .locked
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
                    if let verdictLabel = verification.statusLabel {
                        HStack(spacing: 6) {
                            Image(systemName: verification.isComplete ? "checkmark.circle.fill" : "eye")
                            Text(verdictLabel)
                        }
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(verification.isComplete ? .green : .primary)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .accessibilityLabel("Step verification: \(verdictLabel). This check is advisory; you decide when to advance.")
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
                    if alignment.alignment == nil {
                        Button("Place Ghost Here") { alignment.placeGhost(manager: camera, proxy: proxy) }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                    } else {
                        AlignmentNudgePad(alignment: alignment)
                    }
                }
            }
            .task {
                camera.checkPermissions()
                startVerificationEvidence()
                registration.frameObserver = { [weak verification] frame, update in
                    verification?.submit(frame: frame, registration: update)
                }
                await loadEntity()
                // Placement can precede the fit sample when geometry loads
                // slowly; make sure tracking starts once both exist.
                registration.refit(alignment: alignment.alignment, relay: camera.registrationRelay)
            }
            .onDisappear {
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
        let service = VLMStepCheckService(
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

    /// With evidence on, records verification windows for this visit and
    /// asks the relay for the colour and occluder channels they keep.
    private func startVerificationEvidence() {
        guard evidenceCaptureEnabled, verificationRecorder == nil,
              let recorder = makePhotoCheckRecorder(staged: nil) else {
            camera.registrationRelay.setAuxiliaryChannels([])
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
        // verifier; after a confirm the window is already written.
        verification.recordWindow(trigger: verification.isComplete ? .stepExit : .override)
        stagedVerification = nil
        verification.stop()
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
            let completedSnapshot = geometry.completedSnapshot(before: step)
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
            let additionSnapshot = geometry.deltaSnapshot(for: step)
            container.addChild(try RealityKitInstructionAdapter.makeEntity(from: additionSnapshot))
            entity = container
            await verification.begin(
                stepID: step.id,
                completedSnapshot: completedSnapshot,
                deltaSnapshot: additionSnapshot,
                stepIndex: step.index - 1
            )
        } catch { self.error = error.localizedDescription }
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
