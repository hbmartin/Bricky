import SwiftData
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let ldrawMPD = UTType(importedAs: "org.ldraw.mpd", conformingTo: .plainText)
    static let ldrawLDR = UTType(importedAs: "org.ldraw.ldr", conformingTo: .plainText)
}

struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var library: InstructionLibraryController
    @EnvironmentObject private var partPack: LDrawPartPackManager
    @Query(sort: \StoredInstructionModel.lastOpenedAt, order: .reverse) private var models: [StoredInstructionModel]
    @State private var importsFile = false
    @State private var importsFolder = false
    @State private var showsRootPicker = false

    var body: some View {
        Group {
            if models.isEmpty {
                ContentUnavailableView {
                    Label("Import Instructions", systemImage: "shippingbox.and.arrow.backward")
                } description: {
                    Text("Bricky reads authored MPD and stepped LDR models with explicit STEP or ROTSTEP boundaries.")
                } actions: {
                    importButtons
                }
            } else {
                List {
                    Section {
                        ForEach(models) { model in
                            NavigationLink {
                                InstructionWorkspaceView(model: model)
                            } label: {
                                ModelLibraryRow(model: model)
                            }
                        }
                    } header: {
                        Text("Instruction Models")
                    }

                    Section {
                        HStack {
                            importButtons
                            Spacer()
                            PartPackBadge(state: partPack.state)
                        }
                    }
                }
            }
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("MPD or LDR File", systemImage: "doc.badge.plus") { importsFile = true }
                    Button("Folder with Custom Files", systemImage: "folder.badge.plus") { importsFolder = true }
                } label: { Label("Import", systemImage: "plus") }
            }
        }
        .overlay { if library.isImporting { ProgressView("Validating authored steps…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
        .fileImporter(isPresented: $importsFile, allowedContentTypes: [.ldrawMPD, .ldrawLDR], allowsMultipleSelection: false) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            Task { _ = await library.importSource(.file(url), into: context) }
        }
        .fileImporter(isPresented: $importsFolder, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            Task {
                _ = await library.importSource(.folder(url), into: context)
                showsRootPicker = !library.rootCandidates.isEmpty
            }
        }
        .sheet(isPresented: $showsRootPicker) {
            NavigationStack {
                List(library.rootCandidates, id: \.self) { candidate in
                    Button(candidate) {
                        showsRootPicker = false
                        Task { _ = await library.importSelectedRoot(candidate, into: context) }
                    }
                }
                .navigationTitle("Choose Root Model")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showsRootPicker = false } } }
            }
            .presentationDetents([.medium])
        }
        .alert("Import Failed", isPresented: Binding(
            get: { library.importError != nil },
            set: { if !$0 { library.importError = nil } }
        )) { Button("OK", role: .cancel) {} } message: { Text(library.importError ?? "") }
    }

    @ViewBuilder
    private var importButtons: some View {
        Button("Import File") { importsFile = true }.buttonStyle(.borderedProminent)
        Button("Import Folder") { importsFolder = true }.buttonStyle(.bordered)
    }
}

private struct ModelLibraryRow: View {
    let model: StoredInstructionModel

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.title2)
                .frame(width: 42, height: 42)
                .foregroundStyle(.white)
                .background(.blue.gradient, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 5) {
                Text(model.title).font(.headline)
                ProgressView(value: Double(model.currentStepIndex), total: Double(max(1, model.totalSteps)))
                Text("Step \(model.currentStepIndex) of \(model.totalSteps) · \(model.sourceFilename)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if model.validationWarningCount > 0 {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    .accessibilityLabel("\(model.validationWarningCount) validation warnings")
            }
        }
        .padding(.vertical, 4)
    }
}

struct InstructionWorkspaceView: View {
    @EnvironmentObject private var library: InstructionLibraryController
    let model: StoredInstructionModel
    @State private var plan: InstructionPlan?
    @State private var loadError: String?

    var body: some View {
        List {
            Section("Continue") {
                NavigationLink { GuideView(model: model) } label: { Label("Open 3D Guide", systemImage: "square.stack.3d.up") }
                NavigationLink { RecoveryFlowView(model: model) } label: { Label("Recover My Place", systemImage: "camera.metering.matrix") }
            }
            if let plan {
                Section("Model") {
                    LabeledContent("Authored steps", value: "\(plan.steps.count)")
                    LabeledContent("Placements", value: "\(plan.placementTimeline.count)")
                    LabeledContent("Sections", value: "\(plan.document.sections.count)")
                    LabeledContent("SHA-256", value: String(plan.sourceSHA256.prefix(12)) + "…")
                    LabeledContent("Part pack", value: plan.partPackVersion)
                }
                if !plan.document.diagnostics.isEmpty {
                    Section("Validation") {
                        ForEach(plan.document.diagnostics) { diagnostic in
                            Label(diagnostic.message, systemImage: diagnostic.severity == .error ? "xmark.octagon" : "exclamationmark.triangle")
                        }
                    }
                }
            }
        }
        .navigationTitle(model.title)
        .task {
            do { plan = try library.loadPlan(for: model) }
            catch { loadError = error.localizedDescription }
        }
        .alert("Model Unavailable", isPresented: Binding(get: { loadError != nil }, set: { if !$0 { loadError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(loadError ?? "") }
    }
}

struct PartPackBadge: View {
    let state: LDrawPartPackManager.State
    var body: some View {
        switch state {
        case .ready: Label("Parts ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .downloading(let progress): ProgressView(value: progress).frame(width: 90)
        case .extracting: Label("Installing", systemImage: "archivebox")
        case .checking: ProgressView()
        case .notInstalled: Label("Parts needed", systemImage: "arrow.down.circle")
        case .failed: Label("Parts error", systemImage: "exclamationmark.triangle")
        }
    }
}
