import ARKit
import RealityKit
import SwiftUI

struct ARGuideView: View {
    @EnvironmentObject private var partPack: LDrawPartPackManager
    let plan: InstructionPlan
    let step: AuthoredStep
    @StateObject private var camera = ARCameraManager()
    @StateObject private var alignment = ARAlignmentController()
    @State private var entity: Entity?
    @State private var error: String?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ARInstructionOverlay(session: camera.session, entity: entity, alignment: alignment.alignment)
                    .ignoresSafeArea()
                Image(systemName: "plus").font(.title).foregroundStyle(.white).shadow(radius: 3)
                VStack {
                    HStack {
                        Text(alignment.guidance).font(.callout.weight(.semibold))
                        Spacer()
                        Button("Reset") { alignment.reset() }
                    }
                    .padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14)).padding()
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
                await loadEntity()
            }
            .onDisappear {
                camera.stopSession()
                // Re-entry re-runs the session with reset options, which
                // starts a new world frame; drop the stale ghost pose.
                alignment.reset()
            }
            .onChange(of: camera.trackingState) { _, state in
                if case .notAvailable = state, alignment.alignment != nil { alignment.trackingLost() }
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
            let snapshot = try await engine.snapshot(placements: Array(plan.cumulativePlacements(through: step)))
            entity = try RealityKitInstructionAdapter.makeEntity(from: snapshot)
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
