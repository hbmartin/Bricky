import ARKit
import RealityKit
import SwiftUI

struct ARGuideView: View {
    @EnvironmentObject private var partPack: LDrawPartPackManager
    let plan: InstructionPlan
    let step: AuthoredStep
    @StateObject private var camera = ARCameraManager()
    @StateObject private var alignment = ARAlignmentController()
    @StateObject private var registration = RegistrationController()
    @StateObject private var verification = StepVerificationController()
    @State private var entity: Entity?
    @State private var error: String?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ARInstructionOverlay(
                    session: camera.session,
                    entity: entity,
                    alignment: alignment.alignment,
                    trackedTransform: registration.trackedTransform
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
                    Spacer()
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
                registration.frameObserver = { [weak verification] frame, update in
                    await verification?.observe(frame: frame, registration: update)
                }
                await loadEntity()
            }
            .onDisappear {
                verification.stop()
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
        }
        .navigationTitle("AR Step \(step.index)")
        .navigationBarTitleDisplayMode(.inline)
        .alert("AR Unavailable", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    @MainActor
    private func loadEntity() async {
        guard let partPackRoot = partPack.libraryURL else { error = "Install the LDraw part pack first."; return }
        do {
            let root = try InstructionModelImporter.applicationSupportRoot()
            let source = root.appendingPathComponent("Models/\(plan.sourceSHA256)/Source")
            let engine = LDrawGeometryEngine(sourceRoot: source, partPackRoot: partPackRoot)
            // Same completed/new treatment as the on-screen guide: dimmed
            // prior work under a full-opacity ghost of this step's additions.
            // Both stay solid translucent renders — never wireframe — per the
            // ADR 0008 design-around.
            let completed = Array(plan.completedPlacements(before: step))
            let additions = Array(plan.addedPlacements(for: step))
            let container = Entity()
            let completedSnapshot = try await engine.snapshot(placements: completed)
            if !completed.isEmpty {
                container.addChild(try RealityKitInstructionAdapter.makeEntity(from: completedSnapshot, dimmed: true))
                // The physical build at this point is the completed geometry;
                // that is what the depth tracker registers against.
                registration.setFitSample(
                    ModelSurfaceSampler.sample(completedSnapshot, stepIndex: step.index)
                )
            } else {
                registration.setFitSample(nil)
            }
            let additionSnapshot = try await engine.snapshot(placements: additions)
            container.addChild(try RealityKitInstructionAdapter.makeEntity(from: additionSnapshot))
            entity = container
            verification.begin(
                stepID: step.id,
                completedSnapshot: completedSnapshot,
                deltaSnapshot: additionSnapshot
            )
        } catch { self.error = error.localizedDescription }
    }
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
