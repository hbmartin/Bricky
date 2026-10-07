import SwiftUI

/// Corpus-collection declaration sheet: the expected step and conditions are
/// stated before capture so the session produces a fully-populated
/// `RecoveryBenchmarkV1` row with declared (not post-hoc) ground truth.
struct StagedFixtureSetupView: View {
    let plan: InstructionPlan
    @Binding var declaration: StagedFixtureDeclaration?
    @Environment(\.dismiss) private var dismiss
    @State private var draft: StagedFixtureDeclaration
    @State private var buildLabel: String
    private let buildLabels: PhysicalBuildLabelStore

    init(
        plan: InstructionPlan,
        declaration: Binding<StagedFixtureDeclaration?>,
        buildLabels: PhysicalBuildLabelStore = PhysicalBuildLabelStore()
    ) {
        self.plan = plan
        self.buildLabels = buildLabels
        _buildLabel = State(initialValue: buildLabels.label(forInstruction: plan.sourceSHA256) ?? "")
        _declaration = declaration
        _draft = State(initialValue: declaration.wrappedValue ?? StagedFixtureDeclaration(
            expectedCompletedCount: 0,
            lighting: .bright,
            occlusion: .none,
            physicalCase: true,
            legalUseConfirmed: false
        ))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("True last completed step") {
                    Picker("Last completed", selection: $draft.expectedCompletedCount) {
                        Text("Step 0 · Not started").tag(0)
                        ForEach(plan.steps) { step in
                            Text("Step \(step.index)").tag(step.index)
                        }
                    }
                }
                Section("Conditions") {
                    Picker("Lighting", selection: $draft.lighting) {
                        ForEach(StagedFixtureDeclaration.Lighting.allCases, id: \.self) {
                            Text($0.rawValue.capitalized).tag($0)
                        }
                    }
                    Picker("Occlusion", selection: $draft.occlusion) {
                        ForEach(StagedFixtureDeclaration.Occlusion.allCases, id: \.self) {
                            Text($0.rawValue.capitalized).tag($0)
                        }
                    }
                    Toggle("Physical build present", isOn: $draft.physicalCase)
                }
                Section {
                    TextField("Build label", text: $buildLabel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: buildLabel) { _, typed in
                            let normalized = PhysicalBuildLabelStore.normalized(typed)
                            if normalized != typed { buildLabel = normalized }
                        }
                    Button("New Build") { buildLabel = PhysicalBuildLabelStore.newLabel() }
                } header: {
                    Text("Physical build")
                } footer: {
                    Text("Use the same label every time you photograph this same physical build, and a new one when you rebuild it. Training and test data are split by it.")
                }
                .disabled(!draft.physicalCase)
                Section {
                    Toggle("I can legally use this model for benchmarking", isOn: $draft.legalUseConfirmed)
                } footer: {
                    Text("Required for release-corpus rows. The declared step is recorded as ground truth even if you confirm a different step afterward.")
                }
            }
            .navigationTitle("Staged Fixture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        declaration = draft
                        // Without a physical build there is nothing to label,
                        // and the remembered label is kept for the next one.
                        if draft.physicalCase {
                            buildLabels.setLabel(buildLabel, forInstruction: plan.sourceSHA256)
                        }
                        dismiss()
                    }
                    .disabled(!draft.legalUseConfirmed)
                }
            }
        }
    }
}

/// Opens the staged declaration sheet and shows what is declared, so a
/// corpus session is never collected against a stale or missing label.
struct StagedDeclarationButton: View {
    let declaration: StagedFixtureDeclaration?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(
                declaration.map { "Staged fixture: Step \($0.expectedCompletedCount)" }
                    ?? "Staged fixture: not declared",
                systemImage: declaration == nil ? "flag.slash" : "flag.checkered"
            )
            .font(.caption.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .tint(declaration == nil ? .orange : .green)
    }
}
