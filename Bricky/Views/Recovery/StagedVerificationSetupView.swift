import SwiftUI

/// Corpus-collection declaration for the step the AR guide is verifying: the
/// physical state is stated before the verifier sees it, so the evidence
/// window written when the step closes carries declared ground truth.
struct StagedVerificationSetupView: View {
    @Binding var declaration: StagedVerificationDeclaration?
    let stepIndex: Int
    @Environment(\.dismiss) private var dismiss
    @State private var draft: StagedVerificationDeclaration

    init(declaration: Binding<StagedVerificationDeclaration?>, stepIndex: Int) {
        _declaration = declaration
        self.stepIndex = stepIndex
        _draft = State(initialValue: declaration.wrappedValue ?? StagedVerificationDeclaration(
            scenario: .complete,
            lighting: .bright,
            occlusion: .none,
            physicalCase: true,
            legalUseConfirmed: false
        ))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("How step \(stepIndex) is built") {
                    Picker("State", selection: $draft.scenario) {
                        ForEach(StagedVerificationDeclaration.Scenario.allCases, id: \.self) { scenario in
                            Text(Self.title(scenario)).tag(scenario)
                        }
                    }
                    if draft.scenario == .shiftedOneStud {
                        TextField("Which way, from where you stand", text: Binding(
                            get: { draft.shiftDirectionUser ?? "" },
                            set: { draft.shiftDirectionUser = $0.isEmpty ? nil : $0 }
                        ))
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
                    Text("Recorded as ground truth for this step's verification evidence, whatever the verifier says.")
                }
            }
            .navigationTitle("Staged Verification")
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

    private static func title(_ scenario: StagedVerificationDeclaration.Scenario) -> String {
        switch scenario {
        case .complete: "Complete"
        case .missing: "Step's parts missing"
        case .shiftedOneStud: "Shifted one stud"
        case .rotated: "Part rotated"
        case .wrongColour: "Wrong colour"
        case .plateOffset: "One plate too high or low"
        case .handOccluding: "Complete, hand in view"
        }
    }
}
