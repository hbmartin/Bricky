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
                    checkTask?.cancel()
                    checkTask = nil
                    camera.stopSession()
                    discardRawCapture()
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
    }

    private func resultCard(_ value: StepCheckResult) -> some View {
        VStack(spacing: 12) {
            Label(value.rawValue.capitalized, systemImage: icon(value)).font(.title2.bold())
            Text("This result is advisory. Your authored guide remains under your control.")
                .font(.caption).multilineTextAlignment(.center)
            HStack {
                Button("Retake") {
                    discardRawCapture()
                    result = nil
                }
                Button(value == .complete ? "Confirm & Advance" : "Advance Anyway") { advance() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18)).padding()
    }

    private func icon(_ value: StepCheckResult) -> String {
        switch value {
        case .complete: "checkmark.circle.fill"
        case .incomplete: "xmark.circle.fill"
        case .uncertain: "questionmark.circle.fill"
        }
    }

    private func check() {
        guard let pack = partPack.libraryURL, let modelDirectory = recoveryModel.modelDirectory else {
            error = "Step checks need the verified LDraw part pack and the on-device recovery model. Install both in Storage."
            return
        }
        isChecking = true
        checkTask?.cancel()
        let task = Task {
            defer { isChecking = false }
            do {
                let capture = try RecoveryCaptureService().capture(from: camera, angle: .center, alignmentID: UUID())
                let root = try InstructionModelImporter.applicationSupportRoot()
                let physical = root.appendingPathComponent(capture.imageRelativePath)
                capturedURL = physical
                capturedImage = UIImage(contentsOfFile: physical.path)
                let renderer = try InstructionSnapshotRenderer(plan: plan, partPackRoot: pack)
                let candidate = try await renderer.image(forStepIndex: step.index - 1)
                let board = try RecoveryBoardComposer.compose(
                    physicalViewURL: physical,
                    candidates: [(slot: "A", image: candidate, stepNumber: step.index)]
                )
                defer { try? FileManager.default.removeItem(at: board) }
                let output = try await recoveryModel.runtime.checkStep(
                    imageURL: board,
                    prompt: "The top image is the physical build. Candidate A is the cumulative authored target for this step. Decide complete, incomplete, or uncertain. Do not diagnose individual missing parts.",
                    modelDirectory: modelDirectory
                )
                result = StepCheckResult(rawValue: output.result) ?? .uncertain
            } catch is CancellationError {
                // Navigation or suspension cancelled the check.
            } catch { self.error = error.localizedDescription }
        }
        checkTask = task
        // Registered so the app can cancel AND await in-flight MLX inference
        // before unloading the runtime on suspension.
        recoveryModel.trackInference(task)
    }

    private func advance() {
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
}
