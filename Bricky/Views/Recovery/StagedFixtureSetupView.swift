import SwiftUI

/// Corpus-collection declaration sheet: the expected step and conditions are
/// stated before capture so the session produces a fully-populated
/// `RecoveryBenchmarkV1` row with declared (not post-hoc) ground truth.
struct StagedFixtureSetupView: View {
    let plan: InstructionPlan
    @Binding var declaration: StagedFixtureDeclaration?
    @Environment(\.dismiss) private var dismiss
    @State private var draft: StagedFixtureDeclaration

    init(plan: InstructionPlan, declaration: Binding<StagedFixtureDeclaration?>) {
        self.plan = plan
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
                        dismiss()
                    }
                    .disabled(!draft.legalUseConfirmed)
                }
            }
        }
    }
}
