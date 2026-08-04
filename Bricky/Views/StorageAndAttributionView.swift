import SwiftUI

struct StorageAndAttributionView: View {
    @EnvironmentObject private var partPack: LDrawPartPackManager
    @EnvironmentObject private var recoveryModel: RecoveryModelManager
    @AppStorage(AppConfig.Defaults.evidenceCaptureEnabled) private var evidenceCaptureEnabled = false
    @AppStorage(AppConfig.Defaults.corpusCollectionEnabled) private var corpusCollectionEnabled = false

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
                Text("Qwen2.5-VL-3B-Instruct 4-bit · pinned revision \(RecoveryModelManager.revision.prefix(12))…")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Label("Images and instruction models stay on this device", systemImage: "lock.shield.fill")
                Text("Instruction models and recovery images remain on this device. Recovery analysis runs locally.")
            }

            Section {
                Toggle("Record recovery evidence", isOn: $evidenceCaptureEnabled)
                Toggle("Corpus collection mode", isOn: $corpusCollectionEnabled)
                    .disabled(!evidenceCaptureEnabled)
                NavigationLink("Evidence Sessions") { EvidenceSessionsView() }
            } header: {
                Text("Developer")
            } footer: {
                Text("Off by default. When enabled, recovery runs record full inference evidence (images, prompts, raw model output) on this device. Nothing leaves the device unless you export a bundle manually (ADR 0007).")
            }
        }
        .navigationTitle("Storage")
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
}
