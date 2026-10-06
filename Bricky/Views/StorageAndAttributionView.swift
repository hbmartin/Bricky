import SwiftUI

struct StorageAndAttributionView: View {
    @EnvironmentObject private var partPack: LDrawPartPackManager
    @EnvironmentObject private var recoveryModel: RecoveryModelManager
    @AppStorage(AppConfig.Defaults.evidenceCaptureEnabled) private var evidenceCaptureEnabled = false
    @AppStorage(AppConfig.Defaults.corpusCollectionEnabled) private var corpusCollectionEnabled = false
    @AppStorage(AppConfig.Defaults.cloudAssistEnabled) private var cloudAssistEnabled = false
    @AppStorage(AppConfig.Defaults.idleUnloadEnabled) private var idleUnloadEnabled = false
    @AppStorage(AppConfig.Defaults.suggestedPlacementEnabled) private var suggestedPlacementEnabled = false
    @AppStorage(AppConfig.Defaults.handsFreeEnabled) private var handsFreeEnabled = false
    @State private var apiKeyDraft = ""
    @State private var apiKeyStored = CloudAssistKeyStore.hasKey
    @State private var keychainError: String?
    @State private var confirmModelRemoval = false
    @State private var armPlan = InferenceArmScheduler().plan
    @State private var modelRemovalError: String?

    var body: some View {
        List {
            Section("LDraw Parts") {
                LabeledContent("Version", value: LDrawPartPackManager.version)
                PartPackBadge(state: partPack.state)
                if case .notInstalled = partPack.state {
                    Button("Download Verified Part Pack") { Task { await partPack.install() } }
                }
                Text(LDrawPartPackManager.attribution).font(.caption).foregroundStyle(.secondary)
                Link("LDraw attribution and licenses", destination: URL(string: "https://library.ldraw.org/updates")!)
            }

            Section("Private Recovery Model") {
                recoveryStatus
                Toggle("Allow cellular download", isOn: $recoveryModel.allowsCellularDownloads)
                if case .needsDownload = recoveryModel.state {
                    Button("Download On-Device Model") { recoveryModel.download() }
                }
                if case .rejected = recoveryModel.state, recoveryModel.rejectionIsRetryable {
                    Button("Retry Recovery Check") { Task { await recoveryModel.check() } }
                }
                let onDisk = recoveryModel.onDiskBytes
                if onDisk > 0 {
                    LabeledContent("On this device", value: ByteCountFormatter.string(fromByteCount: onDisk, countStyle: .file))
                    Button("Remove On-Device Model", role: .destructive) { confirmModelRemoval = true }
                        .confirmationDialog(
                            "Remove the on-device recovery model?",
                            isPresented: $confirmModelRemoval,
                            titleVisibility: .visible
                        ) {
                            Button("Remove Model", role: .destructive) {
                                Task {
                                    do { try await recoveryModel.removeModel() } catch { modelRemovalError = error.localizedDescription }
                                }
                            }
                        } message: {
                            Text("Frees \(ByteCountFormatter.string(fromByteCount: onDisk, countStyle: .file)). Guides and depth-based checks keep working; photo-based recovery needs the model downloaded again.")
                        }
                }
                if let modelRemovalError {
                    Text(modelRemovalError).font(.caption).foregroundStyle(.red)
                }
                Text("Qwen3-VL-4B-Instruct 4-bit · pinned revision \(RecoveryModelManager.revision.prefix(12))…")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Label("Images and instruction models stay on this device", systemImage: "lock.shield.fill")
                Text("Instruction models and LDraw files never leave the device. Images leave only through actions you take explicitly: exporting an evidence bundle, or sending one consented frame via cloud assist.")
            }

            Section {
                Toggle("Enable cloud assist", isOn: $cloudAssistEnabled)
                if apiKeyStored {
                    LabeledContent("Anthropic API key", value: "Stored in Keychain")
                    Button("Remove Key", role: .destructive) {
                        CloudAssistKeyStore.delete()
                        apiKeyStored = false
                    }
                } else {
                    SecureField("Anthropic API key", text: $apiKeyDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Save Key") {
                        do {
                            try CloudAssistKeyStore.save(apiKeyDraft)
                            apiKeyDraft = ""
                            apiKeyStored = CloudAssistKeyStore.hasKey
                        } catch {
                            keychainError = error.localizedDescription
                        }
                    }
                    .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } header: {
                Text("Cloud Assist")
            } footer: {
                Text("Off by default. When enabled and a step check is uncertain, you can ask Claude for a second opinion using your own Anthropic API key. Each send shows the exact image first and requires your confirmation; one frame per send, straight from this device to Anthropic, with no server in between (ADR 0011).")
            }

            Section {
                Toggle("Record recovery evidence", isOn: $evidenceCaptureEnabled)
                Toggle("Corpus collection mode", isOn: $corpusCollectionEnabled)
                    .disabled(!evidenceCaptureEnabled)
                NavigationLink("Evidence Sessions") { EvidenceSessionsView() }
                Toggle("Unload model after 5 idle minutes", isOn: $idleUnloadEnabled)
                Toggle("Offer a suggested ghost position", isOn: $suggestedPlacementEnabled)
                Toggle("Hands-free in the AR guide", isOn: $handsFreeEnabled)
                if let relief = recoveryModel.lastPressureRelief {
                    LabeledContent(
                        "Last memory-pressure unload",
                        value: ByteCountFormatter.string(fromByteCount: relief.freedBytes, countStyle: .memory) + " freed"
                    )
                }
                if evidenceCaptureEnabled {
                    Picker("Inference arms", selection: $armPlan.mode) {
                        Text("Baseline only").tag(InferenceArmScheduler.Mode.off)
                        Text("Variant every time").tag(InferenceArmScheduler.Mode.single)
                        Text("Interleave A/B").tag(InferenceArmScheduler.Mode.interleave)
                    }
                    if armPlan.mode != .off {
                        Picker("Variant decoder", selection: $armPlan.variant.decode) {
                            ForEach(DecodeMode.allCases.filter { $0 != .upstream }, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        Toggle("Variant: unique slots", isOn: $armPlan.variant.uniqueSlots)
                        Picker("Variant scoring", selection: $armPlan.variant.scoring) {
                            ForEach(ScoringMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        Picker("Variant slot order", selection: $armPlan.variant.slotOrder) {
                            ForEach(SlotOrder.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        Picker("Variant board", selection: $armPlan.variant.boardLayout) {
                            ForEach(BoardLayoutVersion.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        Picker("Variant labels", selection: $armPlan.variant.labels) {
                            ForEach(TileLabelStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        Picker("Variant prompt", selection: $armPlan.variant.promptStyle) {
                            ForEach(PromptStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        Picker("Variant image side", selection: $armPlan.variant.imageSide) {
                            ForEach([768, 1024, 1280], id: \.self) { Text("\($0) px").tag($0) }
                        }
                        Picker("Variant vote", selection: $armPlan.variant.vote) {
                            ForEach(RecoveryVoteRule.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        Picker("Variant check target", selection: $armPlan.variant.checkTarget) {
                            ForEach(CheckTarget.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        LabeledContent("Variant ID", value: armPlan.variant.id)
                        if let problem = Self.variantProblem(armPlan.variant) {
                            Label("\(problem). Recoveries run the baseline until this is fixed.", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            } header: {
                Text("Developer")
            } footer: {
                Text("Off by default. When enabled, recovery runs record full inference evidence (images, prompts, raw model output) on this device. Nothing leaves the device unless you export a bundle manually (ADR 0007).")
            }
        }
        .navigationTitle("Storage")
        .onChange(of: armPlan) { _, plan in InferenceArmScheduler().plan = plan }
        .alert("Keychain Error", isPresented: Binding(get: { keychainError != nil }, set: { if !$0 { keychainError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(keychainError ?? "") }
    }

    @ViewBuilder
    private var recoveryStatus: some View {
        switch recoveryModel.state {
        case .checking: Label("Checking this device", systemImage: "checkmark.shield")
        case .needsDownload(let bytes): LabeledContent("Download", value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        case .downloading(let progress): ProgressView(value: progress) { Text("Downloading") }
        case .warming: Label("Ready for AR warm-up", systemImage: "flame")
        case .admitted: Label("Recovery admitted", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
        case .rejected(let reason): Label(reason, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private static func variantProblem(_ variant: RecoveryInferenceVariant) -> String? {
        do {
            try variant.validate()
            return nil
        } catch {
            return "\(error)"
        }
    }
}
