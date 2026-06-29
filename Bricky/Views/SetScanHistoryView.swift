import SwiftUI

/// Past LEGO set identifications. Mirrors the mosaic/minifigure history screens:
/// thumbnail, top match, confidence, and a verified badge, with multi-select
/// delete. Tapping a row shows all candidates from that scan.
struct SetScanHistoryView: View {
    @ObservedObject private var store = SetScanHistoryStore.shared
    @State private var selection: Set<UUID> = []
    @State private var editing = false

    private let contentMaxWidth: CGFloat = 640

    var body: some View {
        Group {
            if store.entries.isEmpty {
                emptyState
            } else {
                List(selection: $selection) {
                    ForEach(store.entries) { entry in
                        NavigationLink {
                            SetScanDetailView(entry: entry)
                        } label: {
                            row(entry)
                        }
                    }
                    .onDelete { idx in
                        let ids = Set(idx.map { store.entries[$0].id })
                        store.delete(ids)
                    }
                }
                .frame(maxWidth: contentMaxWidth)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(L10n.setIdHistoryTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !store.entries.isEmpty {
                EditButton()
            }
        }
        .environment(\.editMode, .constant(editing ? .active : .inactive))
    }

    private func row(_ entry: SetScanHistoryStore.ScanEntry) -> some View {
        HStack(spacing: 12) {
            if let thumb = store.thumbnail(for: entry) {
                Image(uiImage: thumb)
                    .resizable().scaledToFill()
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                Image(systemName: "shippingbox")
                    .frame(width: 52, height: 52)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.topName).font(.headline).lineLimit(1)
                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: entry.isVerified ? "checkmark.seal.fill" : "questionmark.diamond")
                .foregroundStyle(entry.isVerified ? .green : .orange)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath").font(.title).foregroundStyle(.secondary)
            Text(L10n.setIdHistoryEmpty).font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

/// Shows every candidate set captured for one history entry.
private struct SetScanDetailView: View {
    let entry: SetScanHistoryStore.ScanEntry
    @ObservedObject private var store = SetScanHistoryStore.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let thumb = store.thumbnail(for: entry) {
                    Image(uiImage: thumb)
                        .resizable().scaledToFit()
                        .frame(maxHeight: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                ForEach(entry.candidates) { set in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(set.displayName).font(.headline)
                        Text("\(set.setNumber) · \(L10n.setIdConfidenceLabel) \(Int((set.confidence * 100).rounded()))%")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
            .frame(maxWidth: 640).frame(maxWidth: .infinity).padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(entry.topName)
        .navigationBarTitleDisplayMode(.inline)
    }
}
