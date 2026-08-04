import RealityKit
import SwiftData
import SwiftUI

struct GuideView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var library: InstructionLibraryController
    @EnvironmentObject private var partPack: LDrawPartPackManager
    let model: StoredInstructionModel
    @State private var plan: InstructionPlan?
    @State private var stepIndex = 0
    @State private var loadError: String?
    @State private var loadedKey: GuideLoadKey?

    var body: some View {
        Group {
            if let plan, !plan.steps.isEmpty {
                let step = plan.steps[stepIndex]
                ScrollView {
                    VStack(spacing: 18) {
                        GuidePreviewView(plan: plan, step: step, partPackRoot: partPack.libraryURL)
                            .frame(minHeight: 330)
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                            .overlay(alignment: .topLeading) {
                                Text("Step \(step.index) of \(plan.steps.count)")
                                    .font(.headline).padding(10).background(.regularMaterial, in: Capsule()).padding()
                            }

                        if let rotation = step.rotationCue {
                            Label(rotation.mode == .end ? "Return to the authored view" : "Rotate view: \(rotation.x, specifier: "%.0f")°, \(rotation.y, specifier: "%.0f")°, \(rotation.z, specifier: "%.0f")°", systemImage: "rotate.3d.fill")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding().background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                        }

                        NewPartsCard(placements: Array(plan.addedPlacements(for: step)))

                        HStack {
                            Button("Previous", systemImage: "chevron.left") { stepIndex = max(0, stepIndex - 1) }
                                .disabled(stepIndex == 0)
                            Spacer()
                            Button(stepIndex == plan.steps.count - 1 ? "Finish" : "Next", systemImage: "chevron.right") {
                                confirmAndAdvance(step: step, plan: plan)
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        // Geometric-first (ADR 0008): the AR overlay carries
                        // live depth verification and one-tap confirm; the
                        // photo check is the VLM advisory fallback.
                        NavigationLink {
                            ARGuideView(model: model, plan: plan, step: step)
                        } label: {
                            Label("Build & Verify in AR", systemImage: "arkit")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).tint(.indigo)

                        NavigationLink {
                            StepCheckView(model: model, plan: plan, step: step)
                        } label: {
                            Label("Photo Check (on-device AI)", systemImage: "camera.viewfinder")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding()
                }
            } else if let loadError {
                ContentUnavailableView {
                    Label("Guide Unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                } actions: {
                    Button("Retry") { load() }.buttonStyle(.borderedProminent)
                }
            } else if plan != nil {
                ContentUnavailableView("No Authored Steps", systemImage: "square.stack.3d.up.slash", description: Text("This model contains no authored steps to guide."))
            } else {
                ProgressView("Loading authored guide…")
            }
        }
        .navigationTitle(model.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { loadIfNeeded() }
    }

    /// Loads once per (model, confirmed step) pair. Plain reappearance (for
    /// example popping back from AR overlay or step check) keeps the user's
    /// browsing position; a recovery confirmation or checked advance changes
    /// `currentStepIndex` and re-lands the guide on the recovered step.
    private func loadIfNeeded() {
        let key = GuideLoadKey(modelID: model.persistentModelID, currentStep: model.currentStepIndex)
        guard key != loadedKey else { return }
        load()
    }

    private func load() {
        do {
            let loaded = try library.loadPlan(for: model)
            plan = loaded
            stepIndex = min(max(0, model.currentStepIndex), max(0, loaded.steps.count - 1))
            loadError = nil
            loadedKey = GuideLoadKey(modelID: model.persistentModelID, currentStep: model.currentStepIndex)
        } catch {
            plan = nil
            loadError = error.localizedDescription
            loadedKey = nil
        }
    }

    private func confirmAndAdvance(step: AuthoredStep, plan: InstructionPlan) {
        model.confirmedLastCompletedStepID = step.id
        model.currentStepIndex = min(plan.steps.count, step.index)
        model.lastOpenedAt = .now
        try? context.save()
        if stepIndex < plan.steps.count - 1 { stepIndex += 1 }
        // In-view advances already reflect the new position; keep the loaded
        // key in sync so the next appearance does not reset browsing.
        loadedKey = GuideLoadKey(modelID: model.persistentModelID, currentStep: model.currentStepIndex)
    }
}

private struct GuideLoadKey: Equatable {
    let modelID: PersistentIdentifier
    let currentStep: Int
}

private struct NewPartsCard: View {
    let placements: [PartPlacement]

    private var groups: [(part: String, color: Int, count: Int)] {
        Dictionary(grouping: placements, by: { "\($0.partReference)|\($0.colorCode)" })
            .values
            .map { ($0[0].partReference, $0[0].colorCode, $0.count) }
            .sorted { ($0.part, $0.color) < ($1.part, $1.color) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New in this step").font(.headline)
            if groups.isEmpty {
                Text("This authored step places a completed submodel.").foregroundStyle(.secondary)
            } else {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    HStack {
                        Circle().fill(Color(uiColor: LDrawPalette.color(group.color))).frame(width: 18, height: 18)
                            .overlay(Circle().stroke(.secondary.opacity(0.3)))
                        Text(group.part).font(.body.monospaced())
                        Spacer()
                        Text("×\(group.count)").font(.headline)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct GuidePreviewView: View {
    let plan: InstructionPlan
    let step: AuthoredStep
    let partPackRoot: URL?
    @State private var scene: Entity?
    @State private var error: String?

    var body: some View {
        ZStack {
            RealityKitModelPreview(entity: scene)
            .background(Color(.secondarySystemBackground))
            if let error {
                ContentUnavailableView("Preview Unavailable", systemImage: "cube.transparent", description: Text(error))
            }
        }
        .task(id: step.id) { await loadScene() }
    }

    @MainActor
    private func loadScene() async {
        guard let partPackRoot else {
            error = "Install the pinned LDraw 2026-07 part pack in Storage."
            return
        }
        do {
            let root = try InstructionModelImporter.applicationSupportRoot()
            let source = root.appendingPathComponent("Models/\(plan.sourceSHA256)/Source")
            let engine = LDrawGeometryEngine(sourceRoot: source, partPackRoot: partPackRoot)
            let completed = Array(plan.completedPlacements(before: step))
            let additions = Array(plan.addedPlacements(for: step))
            let completedSnapshot = try await engine.snapshot(placements: completed)
            let additionSnapshot = try await engine.snapshot(placements: additions)
            let rootEntity = Entity()
            rootEntity.addChild(try RealityKitInstructionAdapter.makeEntity(from: completedSnapshot, dimmed: true))
            rootEntity.addChild(try RealityKitInstructionAdapter.makeEntity(from: additionSnapshot))
            scene = rootEntity
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
