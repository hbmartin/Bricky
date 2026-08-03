import ARKit
import RealityKit
import SwiftData
import SwiftUI

struct RecoveryFlowView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var library: InstructionLibraryController
    @EnvironmentObject private var partPack: LDrawPartPackManager
    @EnvironmentObject private var recoveryModel: RecoveryModelManager
    let model: StoredInstructionModel
    /// Invoked after the user confirms their recovered step so the presenter
    /// can move on to the guide instead of stranding them at ghost placement.
    var onFinished: (() -> Void)? = nil

    @StateObject private var camera = ARCameraManager()
    @StateObject private var alignment = ARAlignmentController()
    @State private var plan: InstructionPlan?
    @State private var ghost: Entity?
    @State private var captures: [RecoveryCapture] = []
    @State private var phase: Phase = .alignment
    @State private var estimate: RecoveryEstimate?
    @State private var selectedCompletedCount = 0
    @State private var errorMessage: String?
    @State private var analysisTask: Task<Void, Never>?
    @State private var warmUpAttempt = 0

    enum Phase { case alignment, capture, analyzing, result }

    var body: some View {
        Group {
            if partPack.state != .ready {
                RecoveryBlockedView(title: "LDraw Parts Needed", message: "Install the verified 2026-07 part pack in Storage before recovery.")
            } else {
                switch recoveryModel.state {
                case .needsDownload:
                    RecoveryBlockedView(title: "On-Device Model Needed", message: "Download the private recovery model in Storage to enable recovery.")
                case .rejected(let reason):
                    RecoveryBlockedView(
                        title: "Recovery Unavailable",
                        message: reason,
                        actionTitle: recoveryModel.rejectionIsRetryable ? "Try Again" : nil,
                        action: { Task { await recoveryModel.check() } }
                    )
                case .checking, .downloading:
                    ProgressView("Checking recovery admission…")
                case .warming:
                    warmUpView
                case .admitted:
                    admittedFlow
                }
            }
        }
        .navigationTitle("Recover My Place")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onDisappear {
            camera.stopSession()
            analysisTask?.cancel()
            analysisTask = nil
            removeUnretainedCaptures()
            estimate = nil
            // Re-entry re-runs the session with reset options, which starts a
            // new world frame; a surviving alignment would be a stale ghost
            // pose, and any transient phase would show a frozen paused camera
            // (only the warm-up and alignment views restart the session).
            alignment.reset()
            phase = .alignment
        }
        .onChange(of: camera.trackingState) { _, state in
            if case .notAvailable = state, alignment.alignment != nil {
                alignment.trackingLost()
                removeUnretainedCaptures()
                phase = .alignment
            }
        }
        .alert("Recovery Stopped", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    private var warmUpView: some View {
        ZStack {
            ARCameraPreview(session: camera.session).ignoresSafeArea()
            VStack {
                Spacer()
                if let cameraError = camera.error {
                    VStack(spacing: 12) {
                        Label("Camera Unavailable", systemImage: "video.slash").font(.headline)
                        Text(cameraError.localizedDescription).font(.caption).multilineTextAlignment(.center)
                        Button("Try Again") { warmUpAttempt += 1 }.buttonStyle(.borderedProminent)
                    }
                    .padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16)).padding()
                } else {
                    ProgressView("Running private on-device fit test…")
                        .padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16)).padding()
                }
            }
        }
        .task(id: warmUpAttempt) {
            camera.checkPermissions()
            // Bail out on cancellation: after cancellation Task.sleep throws
            // immediately, and `try?` would otherwise turn this into a hot
            // spin. A camera error is surfaced by the view above.
            while !Task.isCancelled, !camera.isSessionRunning, camera.error == nil {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled, camera.isSessionRunning else { return }
            recoveryModel.warmUpWhileARIsActive()
        }
    }

    @ViewBuilder
    private var admittedFlow: some View {
        switch phase {
        case .alignment:
            alignmentView
        case .capture:
            captureView
        case .analyzing:
            VStack(spacing: 20) {
                ProgressView().controlSize(.large)
                Text("Comparing authored steps on this device").font(.headline)
                Text("Broad search → narrow interval → three-view agreement").font(.caption).foregroundStyle(.secondary)
            }
        case .result:
            resultView
        }
    }

    private var alignmentView: some View {
        GeometryReader { proxy in
            ZStack {
                ARInstructionOverlay(session: camera.session, entity: ghost, alignment: alignment.alignment).ignoresSafeArea()
                Image(systemName: "plus").font(.title).foregroundStyle(.white).shadow(radius: 3)
                VStack {
                    Text(alignment.guidance).font(.callout.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14)).padding()
                    Spacer()
                    if alignment.alignment == nil {
                        Button("Place Ghost Here") { placeGhost(proxy: proxy) }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                    } else {
                        VStack {
                            RecoveryNudgeControls(alignment: alignment)
                            Button("Ghost Matches My Build") { phase = .capture }
                                .buttonStyle(.borderedProminent).controlSize(.large)
                        }
                    }
                }
            }
        }
        .task { camera.checkPermissions() }
    }

    private var captureView: some View {
        ZStack {
            ARCameraPreview(session: camera.session).ignoresSafeArea()
            VStack {
                let angle = CaptureAngle.allCases[min(captures.count, 2)]
                VStack(spacing: 5) {
                    if captures.count >= 3 {
                        Text("All three views captured").font(.headline)
                        Text("Run the on-device comparison, or retake the views.").font(.caption)
                    } else {
                        Text("Capture \(captures.count + 1) of 3 · \(angle.title)").font(.headline)
                        Text(captureInstruction(angle)).font(.caption)
                    }
                }
                .frame(maxWidth: .infinity).padding().background(.ultraThinMaterial)
                Spacer()
                HStack(spacing: 10) {
                    ForEach(captures) { capture in
                        CaptureThumbnail(capture: capture)
                    }
                }
                if captures.count >= 3 {
                    // A failed analysis returns here with all three views
                    // retained; offer an explicit retry instead of a fourth
                    // capture that could never trigger analysis.
                    HStack {
                        Button("Retake Views", systemImage: "arrow.counterclockwise") { removeUnretainedCaptures() }
                            .buttonStyle(.bordered)
                        Button("Retry Analysis", systemImage: "sparkle.magnifyingglass") { analyze() }
                            .buttonStyle(.borderedProminent)
                    }
                    .controlSize(.large).padding()
                } else {
                    Button("Capture \(angle.title) View", systemImage: "camera.circle.fill") { capture(angle: angle) }
                        .buttonStyle(.borderedProminent).controlSize(.large).padding()
                }
            }
        }
    }

    private var resultView: some View {
        Form {
            Section {
                if let estimate {
                    LabeledContent("Certainty", value: estimate.certainty.rawValue.capitalized)
                    LabeledContent("On-device time", value: String(format: "%.1f s", Double(estimate.latencyMilliseconds) / 1000))
                    if estimate.rankedStepIDs.isEmpty {
                        Text("The views were insufficient. Choose the last completed authored step yourself.")
                    } else if let plan {
                        ForEach(estimate.rankedStepIDs, id: \.self) { id in
                            if id == plan.stepZeroID {
                                Button("Step 0 · Not started") { selectedCompletedCount = 0 }
                            } else if let step = plan.steps.first(where: { $0.id == id }) {
                                Button("Step \(step.index)") { selectedCompletedCount = step.index }
                            }
                        }
                    }
                }
            } header: { Text("Advisory Estimate") }

            if let plan {
                Section("Confirm last completed step") {
                    Picker("Last completed", selection: $selectedCompletedCount) {
                        Text("Step 0 · Not started").tag(0)
                        ForEach(plan.steps) { step in Text("Step \(step.index)").tag(step.index) }
                    }
                }
                Section {
                    Button("Continue Guide") { confirm(plan: plan) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    @MainActor
    private func load() async {
        do {
            let loaded = try library.loadPlan(for: model)
            plan = loaded
            selectedCompletedCount = model.currentStepIndex
            if let pack = partPack.libraryURL {
                ghost = try RealityKitInstructionAdapter.makeEntity(
                    from: await geometrySnapshotForFinal(plan: loaded, partPack: pack), dimmed: true
                )
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func geometrySnapshotForFinal(plan: InstructionPlan, partPack: URL) async throws -> InstructionGeometrySnapshot {
        let root = try InstructionModelImporter.applicationSupportRoot()
        let source = root.appendingPathComponent("Models/\(plan.sourceSHA256)/Source")
        return try await LDrawGeometryEngine(sourceRoot: source, partPackRoot: partPack).snapshot(placements: plan.placementTimeline)
    }

    private func placeGhost(proxy: GeometryProxy) {
        // The AR preview ignores the safe area, so it spans the full window
        // while the GeometryReader (and the centered reticle) only cover the
        // safe area. Express the reticle's position and the viewport in the
        // AR view's window-sized coordinate space.
        let frame = proxy.frame(in: .global)
        let viewport = CGSize(
            width: proxy.size.width + proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing,
            height: proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
        )
        alignment.placeGhost(
            manager: camera,
            viewport: viewport,
            screenPoint: CGPoint(x: frame.midX, y: frame.midY)
        )
    }

    private func capture(angle: CaptureAngle) {
        guard let alignmentID = alignment.alignment?.id else { phase = .alignment; return }
        guard captures.count < 3 else { return }
        do {
            captures.append(try RecoveryCaptureService().capture(from: camera, angle: angle, alignmentID: alignmentID))
            if captures.count >= 3 { analyze() }
        } catch { errorMessage = error.localizedDescription }
    }

    private func analyze() {
        guard let plan, let currentAlignment = alignment.alignment,
              let modelDirectory = recoveryModel.modelDirectory,
              let partPackRoot = partPack.libraryURL else { return }
        phase = .analyzing
        analysisTask?.cancel()
        let capturedViews = captures
        let task = Task {
            do {
                let estimator = HierarchicalRecoveryEstimator(
                    runtime: recoveryModel.runtime,
                    modelDirectory: modelDirectory,
                    partPackRoot: partPackRoot
                )
                let value = try await estimator.estimate(captures: capturedViews, model: plan, alignment: currentAlignment)
                estimate = value
                if let best = value.rankedStepIDs.first {
                    if best == plan.stepZeroID { selectedCompletedCount = 0 }
                    else if let step = plan.steps.first(where: { $0.id == best }) { selectedCompletedCount = step.index }
                }
                phase = .result
            } catch is CancellationError {
                // Cancelled by navigation or suspension; onDisappear resets
                // the transient flow state.
            } catch {
                errorMessage = error.localizedDescription
                phase = .capture
            }
        }
        analysisTask = task
        // Registered so the app can cancel AND await in-flight MLX inference
        // before unloading the runtime on suspension.
        recoveryModel.trackInference(task)
    }

    private func confirm(plan: InstructionPlan) {
        guard !captures.isEmpty else {
            // onDisappear can clear the captures while the result screen is
            // still the stored phase; bail out instead of indexing into an
            // empty array.
            errorMessage = "The recovery views are no longer available. Re-align and capture them again."
            estimate = nil
            phase = .alignment
            return
        }
        let completedStep = selectedCompletedCount == 0 ? nil : plan.steps[selectedCompletedCount - 1]
        let modelID = model.id
        let descriptor = FetchDescriptor<StepMilestoneRecord>(predicate: #Predicate {
            $0.modelID == modelID && $0.isInitialRecoveryView
        })
        var initialDescriptor = descriptor
        initialDescriptor.fetchLimit = 1
        let hasInitialViews = ((try? context.fetch(initialDescriptor))?.isEmpty == false)
        let retainedCaptures: [RecoveryCapture]
        if hasInitialViews {
            retainedCaptures = [captures.first(where: { $0.angle == .center }) ?? captures[0]]
        } else {
            retainedCaptures = captures
        }
        let retainedIDs = Set(retainedCaptures.map(\.id))
        let milestoneStore = RecoveryImageStore()
        do {
            for capture in retainedCaptures {
                _ = try milestoneStore.registerExistingCapture(
                    relativePath: capture.imageRelativePath,
                    modelID: model.id,
                    stepID: completedStep?.id ?? plan.stepZeroID,
                    isInitialRecoveryView: !hasInitialViews,
                    context: context
                )
            }
            if let root = try? InstructionModelImporter.applicationSupportRoot() {
                for capture in captures where !retainedIDs.contains(capture.id) {
                    try? FileManager.default.removeItem(at: root.appendingPathComponent(capture.imageRelativePath))
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        model.confirmedLastCompletedStepID = completedStep?.id
        model.currentStepIndex = min(selectedCompletedCount, plan.steps.count)
        model.lastOpenedAt = .now
        let session = RecoverySessionRecord(modelID: model.id)
        session.confirmedLastCompletedStepID = completedStep?.id
        session.nextTargetStepID = selectedCompletedCount < plan.steps.count ? plan.steps[selectedCompletedCount].id : nil
        session.modelRevision = estimate?.modelRevision
        session.certaintyRawValue = estimate?.certainty.rawValue
        context.insert(session)
        try? context.save()
        captures.removeAll()
        estimate = nil
        phase = .alignment
        onFinished?()
    }

    private func removeUnretainedCaptures() {
        if let root = try? InstructionModelImporter.applicationSupportRoot() {
            for capture in captures {
                try? FileManager.default.removeItem(at: root.appendingPathComponent(capture.imageRelativePath))
            }
        }
        captures.removeAll()
    }

    private func captureInstruction(_ angle: CaptureAngle) -> String {
        switch angle {
        case .left: "Move about 30° to the build’s left."
        case .center: "Center the build and keep the full silhouette visible."
        case .right: "Move about 30° to the build’s right."
        }
    }
}

private struct RecoveryBlockedView: View {
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "lock.trianglebadge.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.borderedProminent)
            }
        }
    }
}

private struct CaptureThumbnail: View {
    let capture: RecoveryCapture
    var body: some View {
        if let root = try? InstructionModelImporter.applicationSupportRoot(),
           let image = UIImage(contentsOfFile: root.appendingPathComponent(capture.imageRelativePath).path) {
            Image(uiImage: image).resizable().scaledToFill().frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

private struct RecoveryNudgeControls: View {
    @ObservedObject var alignment: ARAlignmentController
    var body: some View {
        HStack {
            Button { alignment.nudge(x: -0.002) } label: { Image(systemName: "arrow.left") }
                .accessibilityLabel("Move ghost left")
            Button { alignment.nudge(z: -0.002) } label: { Image(systemName: "arrow.up") }
                .accessibilityLabel("Move ghost forward")
            Button { alignment.nudge(yawDegrees: -1) } label: { Image(systemName: "rotate.left") }
                .accessibilityLabel("Rotate ghost left")
            Button { alignment.nudge(yawDegrees: 1) } label: { Image(systemName: "rotate.right") }
                .accessibilityLabel("Rotate ghost right")
            Button { alignment.nudge(z: 0.002) } label: { Image(systemName: "arrow.down") }
                .accessibilityLabel("Move ghost backward")
            Button { alignment.nudge(x: 0.002) } label: { Image(systemName: "arrow.right") }
                .accessibilityLabel("Move ghost right")
        }
        .buttonStyle(.borderedProminent).padding().background(.ultraThinMaterial, in: Capsule())
    }
}
