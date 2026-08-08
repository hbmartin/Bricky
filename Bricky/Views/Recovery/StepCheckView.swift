import RecoveryMLX
import SwiftData
import SwiftUI

struct StepCheckView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var partPack: LDrawPartPackManager
    @EnvironmentObject private var recoveryModel: RecoveryModelManager
    let model: StoredInstructionModel
    let plan: InstructionPlan
    let step: AuthoredStep

    @StateObject private var camera = ARCameraManager()
    @State private var result: StepCheckResult?
    @State private var isChecking = false
    @State private var capturedImage: UIImage?
    @State private var capturedURL: URL?
    @State private var error: String?
    @State private var checkTask: Task<Void, Never>?
    @State private var checkGeneration = UUID()
    @AppStorage(AppConfig.Defaults.evidenceCaptureEnabled) private var evidenceCaptureEnabled = false
    @State private var recorder: RecoveryEvidenceRecorder?
    @AppStorage(AppConfig.Defaults.cloudAssistEnabled) private var cloudAssistEnabled = false
    @State private var boardJPEG: Data?
    @State private var cloudOpinion: CloudAssistOpinion?
    @State private var cloudTask: Task<Void, Never>?
    @State private var cloudGeneration = UUID()
    @State private var isSendingCloud = false
    @State private var showCloudConsent = false

    var body: some View {
        Group {
            if case .admitted = recoveryModel.state {
                ZStack {
                    ARCameraPreview(session: camera.session).ignoresSafeArea()
                    VStack {
                        Text("Frame the full build at authored step \(step.index)")
                            .font(.headline).frame(maxWidth: .infinity).padding().background(.ultraThinMaterial)
                        Spacer()
                        if let result {
                            resultCard(result)
                        } else {
                            Button("Check Step", systemImage: "camera.viewfinder") { check() }
                                .buttonStyle(.borderedProminent).controlSize(.large).disabled(isChecking)
                                .overlay { if isChecking { ProgressView() } }
                                .padding()
                        }
                    }
                }
                .task { camera.checkPermissions() }
                .onDisappear {
                    camera.stopSession()
                    cancelCheckAndDiscardCapture()
                }
            } else {
                ContentUnavailableView("Check Step Unavailable", systemImage: "lock.shield", description: Text("Step checks require an admitted on-device recovery model. You can always advance the guide without a check."))
            }
        }
        .navigationTitle("Check Step \(step.index)")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Check Failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
        .sheet(isPresented: $showCloudConsent) { cloudConsentSheet }
    }

    private func resultCard(_ value: StepCheckResult) -> some View {
        VStack(spacing: 12) {
            Label(value.rawValue.capitalized, systemImage: icon(value)).font(.title2.bold())
            Text("This result is advisory. Your authored guide remains under your control.")
                .font(.caption).multilineTextAlignment(.center)
            if value == .uncertain {
                cloudAssistSection
            }
            HStack {
                Button("Retake") {
                    finalizeEvidence(groundTruth: .unlabeled)
                    cancelCloudRequest()
                    discardRawCapture()
                    result = nil
                    boardJPEG = nil
                    cloudOpinion = nil
                }
                Button(value == .complete ? "Confirm & Advance" : "Advance Anyway") { advance() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18)).padding()
    }

    /// The cloud escape hatch (ADR 0011): offered only after the local
    /// pipeline returned uncertain, only with the toggle on, and every send
    /// passes through the consent sheet showing the exact image.
    @ViewBuilder
    private var cloudAssistSection: some View {
        if let cloudOpinion {
            VStack(spacing: 4) {
                Label("Claude: \(cloudOpinion.verdict.rawValue.capitalized)", systemImage: "cloud")
                    .font(.headline)
                Text(cloudOpinion.rationale)
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        } else if cloudAssistEnabled {
            if CloudAssistKeyStore.hasKey {
                Button("Ask Claude for a Second Opinion", systemImage: "cloud") {
                    showCloudConsent = true
                }
                .disabled(isSendingCloud || boardJPEG == nil)
                .overlay { if isSendingCloud { ProgressView() } }
            } else {
                Text("Add your Anthropic API key in Storage to use cloud assist.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var cloudConsentSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let boardJPEG, let image = UIImage(data: boardJPEG) {
                    Image(uiImage: image)
                        .resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                Text("This exact image will be sent to Anthropic using your API key. Nothing else leaves the device.")
                    .font(.footnote).multilineTextAlignment(.center)
                Button("Send This Image") {
                    showCloudConsent = false
                    sendToCloud()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .navigationTitle("Send to Claude?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showCloudConsent = false }
                }
            }
        }
    }

    private func sendToCloud() {
        guard let boardJPEG, !isSendingCloud else { return }
        isSendingCloud = true
        let generation = UUID()
        cloudGeneration = generation
        let context = CloudAssistContext(stepIndex: step.index, stepCount: plan.steps.count)
        cloudTask = Task {
            // A rotated generation means a Retake or cancel superseded this
            // request; a stale task must not touch state that now describes
            // a different capture.
            defer {
                if generation == cloudGeneration { isSendingCloud = false }
            }
            do {
                let opinion = try await ClaudeVisionProvider()
                    .secondOpinion(boardJPEG: boardJPEG, context: context)
                guard generation == cloudGeneration else { return }
                cloudOpinion = opinion
            } catch is CancellationError {
                // View dismissed mid-send.
            } catch {
                guard generation == cloudGeneration else { return }
                self.error = error.localizedDescription
            }
        }
    }

    /// Invalidates the in-flight cloud request before capture state is
    /// cleared. The rotated generation makes the cancelled task's defer skip
    /// its reset, so the flag is recovered here.
    private func cancelCloudRequest() {
        cloudGeneration = UUID()
        cloudTask?.cancel()
        cloudTask = nil
        isSendingCloud = false
    }

    private func icon(_ value: StepCheckResult) -> String {
        switch value {
        case .complete: "checkmark.circle.fill"
        case .incomplete: "xmark.circle.fill"
        case .uncertain: "questionmark.circle.fill"
        }
    }

    private func check() {
        guard let pack = partPack.readyLibraryURL, let modelDirectory = recoveryModel.modelDirectory else {
            error = "Step checks need the verified LDraw part pack and the on-device recovery model. Install both in Storage."
            return
        }
        isChecking = true
        let previous = checkTask
        previous?.cancel()
        // Claim the superseded check's raw capture now and delete it once its
        // reader task finishes; otherwise the file would linger on disk until
        // the next-launch orphan sweep. The stale image stays visible until
        // this check replaces it.
        let previousCaptureURL = capturedURL
        capturedURL = nil
        boardJPEG = nil
        cloudOpinion = nil
        let generation = UUID()
        checkGeneration = generation
        let sessionRecorder = makeRecorderIfEnabled()
        recorder = sessionRecorder
        let task = Task {
            await previous?.value
            RecoveryWorkFileCleanup.remove(urls: [previousCaptureURL].compactMap { $0 })
            defer {
                if generation == checkGeneration { isChecking = false }
            }
            do {
                try Task.checkCancellation()
                let capture = try RecoveryCaptureService().capture(from: camera, angle: .center, alignmentID: UUID())
                let root = try InstructionModelImporter.applicationSupportRoot()
                let physical = root.appendingPathComponent(capture.imageRelativePath)
                capturedURL = physical
                capturedImage = UIImage(contentsOfFile: physical.path)
                await sessionRecorder?.recordCaptures([capture])
                let renderer = try InstructionSnapshotRenderer(plan: plan, partPackRoot: pack)
                let candidate = try await renderer.image(forStepIndex: step.index - 1)
                let board = try RecoveryBoardComposer.compose(
                    physicalViewURL: physical,
                    candidates: [(slot: "A", image: candidate, stepNumber: step.index)]
                )
                defer { try? FileManager.default.removeItem(at: board) }
                // Retained so cloud assist can show and send the identical
                // board the local model judged (ADR 0011).
                boardJPEG = try Data(contentsOf: board)
                let prompt = "The top image is the physical build. Candidate A is the cumulative authored target for this step. Decide complete, incomplete, or uncertain. Do not diagnose individual missing parts."
                let response = try await recoveryModel.runtime.checkStepWithTrace(
                    imageURL: board,
                    prompt: prompt,
                    modelDirectory: modelDirectory
                )
                await sessionRecorder?.recordPass(
                    pass: .check,
                    passIndex: 0,
                    capture: capture,
                    candidates: [.init(
                        slot: "A",
                        stepIndex: step.index - 1,
                        stepID: step.id,
                        jpegData: candidate.jpegData(compressionQuality: 0.9)
                    )],
                    boardURL: board,
                    prompt: prompt,
                    trace: response.trace
                )
                guard let output = response.output else { throw MLXRecoveryError.invalidStructuredOutput }
                guard generation == checkGeneration, !Task.isCancelled else { return }
                result = StepCheckResult(rawValue: output.result) ?? .uncertain
            } catch is CancellationError {
                // Navigation or suspension cancelled the check.
            } catch {
                await sessionRecorder?.finalize(
                    estimate: nil,
                    analysisError: String(describing: error),
                    groundTruth: .unlabeled
                )
                guard generation == checkGeneration else { return }
                self.error = error.localizedDescription
            }
        }
        checkTask = task
        // Registered so the app can cancel AND await in-flight MLX inference
        // before unloading the runtime on suspension.
        recoveryModel.trackInference(task)
    }

    private func advance() {
        // "Confirm & Advance" after a complete verdict is a human label that
        // the build matches this step; "Advance Anyway" is not.
        if result == .complete {
            finalizeEvidence(groundTruth: EvidenceGroundTruth(
                kind: .confirmed,
                expectedCompletedCount: step.index,
                expectedStepID: step.id,
                confirmedCompletedCount: step.index,
                confirmedAt: .now
            ))
        } else {
            finalizeEvidence(groundTruth: .unlabeled)
        }
        model.confirmedLastCompletedStepID = step.id
        model.currentStepIndex = min(step.index, plan.steps.count)
        model.lastOpenedAt = .now
        if let capturedImage {
            do {
                _ = try RecoveryImageStore().save(
                    image: capturedImage,
                    modelID: model.id,
                    stepID: step.id,
                    isInitialRecoveryView: false,
                    context: context
                )
                discardRawCapture()
            } catch {
                // Keep the view up so the alert is visible; the step advance
                // itself is still persisted below.
                self.error = error.localizedDescription
                try? context.save()
                return
            }
        }
        try? context.save()
        dismiss()
    }

    private func discardRawCapture() {
        if let capturedURL { try? FileManager.default.removeItem(at: capturedURL) }
        capturedURL = nil
        capturedImage = nil
    }

    private func cancelCheckAndDiscardCapture() {
        checkGeneration = UUID()
        // The rotated generation makes the cancelled task's defer skip its
        // reset, so the view must recover the flag here.
        isChecking = false
        let task = checkTask
        checkTask = nil
        task?.cancel()
        cancelCloudRequest()
        let url = capturedURL
        capturedURL = nil
        capturedImage = nil
        boardJPEG = nil
        cloudOpinion = nil
        showCloudConsent = false
        let sessionRecorder = recorder
        recorder = nil
        Task.detached(priority: .utility) {
            await task?.value
            await sessionRecorder?.finalize(estimate: nil, analysisError: nil, groundTruth: .unlabeled)
            RecoveryWorkFileCleanup.remove(urls: [url].compactMap { $0 })
        }
    }

    private func makeRecorderIfEnabled() -> RecoveryEvidenceRecorder? {
        guard evidenceCaptureEnabled, let root = try? InstructionModelImporter.applicationSupportRoot() else { return nil }
        return RecoveryEvidenceRecorder(
            root: root,
            instructionSHA256: plan.sourceSHA256,
            authoredModelID: model.id,
            modelTitle: model.title,
            stepCount: plan.steps.count,
            staged: nil
        )
    }

    private func finalizeEvidence(groundTruth: EvidenceGroundTruth) {
        guard let sessionRecorder = recorder else { return }
        recorder = nil
        Task.detached(priority: .utility) {
            await sessionRecorder.finalize(estimate: nil, analysisError: nil, groundTruth: groundTruth)
        }
    }
}
