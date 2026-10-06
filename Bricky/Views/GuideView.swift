import RealityKit
import SwiftData
import SwiftUI

struct GuideView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(BuildSessionController.self) private var session
    @EnvironmentObject private var library: InstructionLibraryController
    @EnvironmentObject private var partPack: LDrawPartPackManager
    let model: StoredInstructionModel
    @State private var loadError: String?
    @State private var isVisible = false

    /// The session's plan, once it holds this model.
    private var plan: InstructionPlan? {
        session.model?.persistentModelID == model.persistentModelID ? session.plan : nil
    }

    var body: some View {
        Group {
            if let plan, !plan.steps.isEmpty, let step = session.cursorStep {
                ScrollView {
                    VStack(spacing: 18) {
                        GuidePreviewView(plan: plan, step: step, partPackRoot: partPack.readyLibraryURL)
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

                        NewPartsCard(
                            placements: Array(plan.addedPlacements(for: step)),
                            descriptions: descriptionIndex(for: plan)
                        )

                        HStack {
                            Button("Previous", systemImage: "chevron.left") { session.browse(by: -1) }
                                .disabled(session.cursorIndex == 0)
                            Spacer()
                            Button(session.cursorIndex == plan.steps.count - 1 ? "Finish" : "Next", systemImage: "chevron.right") {
                                session.confirm(step, source: .guide)
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        if let persistenceError = session.lastPersistenceError {
                            Label(persistenceError, systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.red)
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
            } else if let plan, plan.steps.isEmpty {
                ContentUnavailableView("No Authored Steps", systemImage: "square.stack.3d.up.slash", description: Text("This model contains no authored steps to guide."))
            } else {
                ProgressView("Loading authored guide…")
            }
        }
        .navigationTitle(model.title)
        .navigationBarTitleDisplayMode(.inline)
        // Opening is idempotent: reappearing (for example after AR or a
        // photo check) keeps the browsing position, while a confirm made
        // anywhere else already moved the shared cursor.
        .task { load() }
        .onAppear {
            isVisible = true
            updateAttendance()
        }
        .onDisappear {
            isVisible = false
            updateAttendance()
        }
        .onChange(of: scenePhase) { _, _ in updateAttendance() }
    }

    /// Someone is at the guide while it is on screen and the app is not in
    /// the background: Siri's "next" may then act (ADR 0016).
    private func updateAttendance() {
        session.setAttending(isVisible && scenePhase != .background, by: "guide")
    }

    /// One index per model and pack, so descriptions stay cached across
    /// steps.
    private func descriptionIndex(for plan: InstructionPlan) -> PartDescriptionIndex? {
        partPack.readyLibraryURL.flatMap { PartDescriptionIndexCache.index(for: plan, partPackRoot: $0) }
    }

    private func load() {
        do {
            try session.open(model, loader: library, context: context)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}

private struct NewPartsCard: View {
    let placements: [PartPlacement]
    let descriptions: PartDescriptionIndex?
    @State private var titles: [String: PartDescription] = [:]

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
                        VStack(alignment: .leading, spacing: 2) {
                            let colour = PartNaming.colourName(code: group.color, definitionName: LDrawPalette.definition(group.color)?.name)
                            Text(titles[group.part].map { PartNaming.label(colour: colour, part: $0) } ?? colour)
                            Text(group.part).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("×\(group.count)").font(.headline)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .task(id: groups.map(\.part)) {
            guard let descriptions else { return }
            for group in groups where titles[group.part] == nil {
                titles[group.part] = await descriptions.description(for: group.part)
            }
        }
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
