import SwiftUI
import UIKit

struct EvidenceSessionsView: View {
    @State private var sessions: [EvidenceExporter.SessionSummary] = []
    @State private var selection = Set<UUID>()
    @State private var editMode: EditMode = .inactive
    @State private var exportedBundle: ExportedBundle?
    @State private var isExporting = false
    @State private var errorMessage: String?

    private struct ExportedBundle: Identifiable {
        let url: URL
        var id: String { url.path }
    }

    private var selectedByteCount: Int64 {
        sessions.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.byteCount }
    }

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(sessions) { session in
                    row(session)
                }
                .onDelete(perform: delete)
            } footer: {
                let total = sessions.reduce(Int64(0)) { $0 + $1.byteCount }
                Text("\(sessions.count) sessions · \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)). Evidence stays on this device until you export it (ADR 0007).")
            }
        }
        .overlay {
            if sessions.isEmpty {
                ContentUnavailableView(
                    "No Evidence Sessions",
                    systemImage: "tray",
                    description: Text("Enable “Record recovery evidence” and run a recovery to capture sessions.")
                )
            }
        }
        .navigationTitle("Evidence Sessions")
        .environment(\.editMode, $editMode)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(editMode == .active ? "Done" : "Select") {
                    editMode = editMode == .active ? .inactive : .active
                    if editMode == .inactive { selection.removeAll() }
                }
                .disabled(sessions.isEmpty)
            }
            ToolbarItem(placement: .bottomBar) {
                if editMode == .active {
                    exportButton
                }
            }
        }
        .sheet(item: $exportedBundle) { bundle in
            ShareSheet(items: [bundle.url])
        }
        .alert("Export Failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
        .task { reload() }
    }

    private func row(_ session: EvidenceExporter.SessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(session.modelTitle).font(.headline)
                Spacer()
                badge(session.groundTruthKind)
            }
            HStack {
                Text(session.createdAt.formatted(date: .abbreviated, time: .shortened))
                Spacer()
                if session.hasBenchmarkRow {
                    Image(systemName: "chart.bar.doc.horizontal")
                        .accessibilityLabel("Has benchmark row")
                }
                Text(ByteCountFormatter.string(fromByteCount: session.byteCount, countStyle: .file))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .tag(session.id)
    }

    private func badge(_ kind: EvidenceGroundTruth.Kind) -> some View {
        Text(kind.rawValue.capitalized)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(badgeColor(kind).opacity(0.2), in: Capsule())
            .foregroundStyle(badgeColor(kind))
    }

    private func badgeColor(_ kind: EvidenceGroundTruth.Kind) -> Color {
        switch kind {
        case .staged: .green
        case .confirmed: .blue
        case .unlabeled: .orange
        }
    }

    private var exportButton: some View {
        Button {
            export()
        } label: {
            if isExporting {
                ProgressView()
            } else {
                Label(
                    "Export \(selection.count) as Bundle · \(ByteCountFormatter.string(fromByteCount: selectedByteCount, countStyle: .file))",
                    systemImage: "square.and.arrow.up"
                )
            }
        }
        .disabled(selection.isEmpty || isExporting)
    }

    private func reload() {
        guard let root = try? InstructionModelImporter.applicationSupportRoot() else { return }
        sessions = EvidenceExporter.listSessions(root: root)
        selection = selection.intersection(sessions.map(\.id))
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            try? FileManager.default.removeItem(at: sessions[index].directory)
        }
        reload()
    }

    private func export() {
        let chosen = sessions.filter { selection.contains($0.id) }
        guard !chosen.isEmpty else { return }
        isExporting = true
        Task.detached(priority: .userInitiated) {
            do {
                let url = try EvidenceExporter.exportBundle(sessions: chosen)
                await MainActor.run {
                    exportedBundle = ExportedBundle(url: url)
                    isExporting = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isExporting = false
                }
            }
        }
    }
}

/// Minimal share-sheet bridge; SwiftUI's ShareLink cannot be presented
/// programmatically after an async export completes.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
