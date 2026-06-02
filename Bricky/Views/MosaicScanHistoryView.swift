import SwiftUI

/// Displays the user's saved LEGO mosaics with their source photo, rendered
/// thumbnail, editable caption/description, and re-shareable exports.
///
/// Mirrors `MinifigureScanHistoryView`:
/// - Thumbnail per row
/// - Multi-select edit mode with select all / deselect all + bulk delete
/// - Swipe-to-delete individual entries
/// - Detail sheet with editable caption/description and LDraw / PDF sharing
struct MosaicScanHistoryView: View {
    @StateObject private var store = MosaicScanHistoryStore.shared

    @State private var selectedEntry: MosaicScanHistoryStore.ScanEntry?
    @State private var isEditing = false
    @State private var selectedIds: Set<UUID> = []
    @State private var showDeleteConfirmation = false

    var body: some View {
        Group {
            if store.entries.isEmpty {
                emptyState
            } else {
                historyList
            }
        }
        .navigationTitle("Mosaic History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !store.entries.isEmpty {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(isEditing ? "Done" : "Edit") {
                        withAnimation {
                            isEditing.toggle()
                            if !isEditing { selectedIds.removeAll() }
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button(role: .destructive) {
                            store.deleteAll()
                        } label: {
                            Label("Clear All History", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .sheet(item: $selectedEntry) { entry in
            MosaicScanHistoryDetailSheet(entry: entry)
        }
        .confirmationDialog(
            "Delete \(selectedIds.count) mosaic\(selectedIds.count == 1 ? "" : "s")?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                store.delete(selectedIds)
                selectedIds.removeAll()
                if store.entries.isEmpty { isEditing = false }
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView(
            "No Mosaics Yet",
            systemImage: "square.grid.3x3",
            description: Text("Mosaics you generate will be saved here.")
        )
    }

    // MARK: - List

    private var historyList: some View {
        VStack(spacing: 0) {
            if isEditing {
                editBar
            }
            List {
                ForEach(store.entries) { entry in
                    HStack(spacing: 10) {
                        if isEditing {
                            Image(systemName: selectedIds.contains(entry.id)
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedIds.contains(entry.id) ? .blue : .secondary)
                                .font(.title3)
                                .onTapGesture { toggleSelection(entry.id) }
                        }
                        Button {
                            if isEditing {
                                toggleSelection(entry.id)
                            } else {
                                selectedEntry = entry
                            }
                        } label: {
                            scanEntryRow(entry)
                        }
                        .buttonStyle(.plain)
                    }
                    .swipeActions(edge: .trailing) {
                        if !isEditing {
                            Button(role: .destructive) {
                                store.delete(entry)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .refreshable {
                store.reload()
            }
        }
    }

    // MARK: - Edit bar (select all / delete selected)

    private var editBar: some View {
        HStack {
            Button {
                if selectedIds.count == store.entries.count {
                    selectedIds.removeAll()
                } else {
                    selectedIds = Set(store.entries.map(\.id))
                }
            } label: {
                let allSelected = selectedIds.count == store.entries.count
                Text(allSelected ? "Deselect All" : "Select All")
                    .font(.subheadline.weight(.semibold))
            }

            Spacer()

            if !selectedIds.isEmpty {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete (\(selectedIds.count))", systemImage: "trash")
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private func toggleSelection(_ id: UUID) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    // MARK: - Row

    private func scanEntryRow(_ entry: MosaicScanHistoryStore.ScanEntry) -> some View {
        HStack(spacing: 12) {
            scanThumbnail(for: entry)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.caption.isEmpty
                     ? "\(entry.gridWidth)×\(entry.gridHeight) Mosaic"
                     : entry.caption)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text("\(entry.gridWidth)×\(entry.gridHeight) studs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(entry.brickCount) bricks")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(entry.date, format: .dateTime.month(.abbreviated).day().year().hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func scanThumbnail(for entry: MosaicScanHistoryStore.ScanEntry) -> some View {
        if let image = store.thumbnail(for: entry) ?? store.sourceImage(for: entry) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.15))
                .overlay {
                    Image(systemName: "square.grid.3x3")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
        }
    }
}

// MARK: - Detail sheet

/// Shows a saved mosaic with editable caption/description and re-share exports.
private struct MosaicScanHistoryDetailSheet: View {
    let entry: MosaicScanHistoryStore.ScanEntry
    @Environment(\.dismiss) private var dismiss

    @StateObject private var store = MosaicScanHistoryStore.shared
    @State private var caption: String
    @State private var detail: String
    @State private var shareURL: ShareURLItem?
    @State private var imageMode: ImageMode = .mosaic
    @State private var previewImage: PreviewImageItem?
    @State private var showRegenerate = false

    /// Which image the detail screen is currently showing.
    private enum ImageMode: Hashable {
        case mosaic
        case original
    }

    init(entry: MosaicScanHistoryStore.ScanEntry) {
        self.entry = entry
        _caption = State(initialValue: entry.caption)
        _detail = State(initialValue: entry.detail)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    mosaicImage

                    captionEditor

                    detailsCard

                    actionButtons
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Mosaic Detail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        save()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationBackground(Color(.systemGroupedBackground))
        .sheet(item: $shareURL) { item in
            ShareSheet(items: [item.url])
        }
        .fullScreenCover(item: $previewImage) { item in
            MosaicImagePreviewView(image: item.image, title: item.title)
        }
        .fullScreenCover(isPresented: $showRegenerate) {
            regenerateCover
        }
    }

    /// The original source photo, if it was persisted with this mosaic.
    private var originalImage: UIImage? {
        store.sourceImage(for: entry)
    }

    /// The size preset the mosaic was generated with, when recognizable.
    private var savedPreset: MosaicGridPreset? {
        MosaicGridPreset(rawValue: entry.gridWidth)
    }

    // MARK: - Sections

    @ViewBuilder
    private var mosaicImage: some View {
        VStack(spacing: 12) {
            if originalImage != nil {
                Picker("", selection: $imageMode) {
                    Text(L10n.mosaicViewMosaic).tag(ImageMode.mosaic)
                    Text(L10n.mosaicViewOriginal).tag(ImageMode.original)
                }
                .pickerStyle(.segmented)
            }

            if let image = displayedImage {
                Button {
                    previewImage = PreviewImageItem(
                        image: image,
                        title: imageMode == .original
                            ? L10n.mosaicViewOriginal
                            : L10n.mosaicViewMosaic
                    )
                } label: {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(Color(.separator))
                        )
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.caption.weight(.semibold))
                                .padding(8)
                                .background(.ultraThinMaterial, in: Circle())
                                .padding(10)
                        }
                }
                .buttonStyle(.plain)
            } else if imageMode == .original {
                Text(L10n.mosaicOriginalUnavailable)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
            }
        }
    }

    /// The image currently selected by the Mosaic/Original toggle.
    private var displayedImage: UIImage? {
        switch imageMode {
        case .mosaic:
            return store.thumbnail(for: entry) ?? originalImage
        case .original:
            return originalImage
        }
    }

    private var captionEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.mosaicCaptionLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField(L10n.mosaicCaptionLabel, text: $caption, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: caption) { _, _ in save() }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.mosaicDescriptionLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextEditor(text: $detail)
                    .frame(minHeight: 96)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(.tertiarySystemBackground))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color(.separator))
                    )
                    .onChange(of: detail) { _, _ in save() }
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\(entry.gridWidth) × \(entry.gridHeight) studs", systemImage: "square.grid.3x3")
            Label("\(entry.brickCount) bricks", systemImage: "cube")
            Label("\(entry.totalParts) total parts", systemImage: "list.bullet")
            if !entry.presetLabel.isEmpty {
                Label(entry.presetLabel, systemImage: "ruler")
            }
            Text(entry.date, format: .dateTime.month(.abbreviated).day().year().hour().minute())
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            if originalImage != nil {
                actionButton(
                    title: L10n.mosaicRegenerate,
                    systemImage: "arrow.triangle.2.circlepath"
                ) {
                    showRegenerate = true
                }
            }
            if let url = store.ldrURL(for: entry) {
                shareButton(title: L10n.mosaicDownloadModel, systemImage: "cube", url: url)
            }
            if let url = store.pdfURL(for: entry) {
                shareButton(title: L10n.mosaicDownloadInstructions, systemImage: "doc.text", url: url)
            }
        }
    }

    /// Opens Mosaic Studio pre-loaded with this mosaic's original photo and
    /// size, so the user can tweak and regenerate. Only reachable when the
    /// original photo was saved.
    @ViewBuilder
    private var regenerateCover: some View {
        NavigationStack {
            MosaicGeneratorView(
                prefillImage: originalImage,
                prefillPreset: savedPreset
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.done) { showRegenerate = false }
                }
            }
        }
    }

    private func actionButton(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private func shareButton(title: String, systemImage: String, url: URL) -> some View {
        Button {
            shareURL = ShareURLItem(url: url)
        } label: {
            Label(title, systemImage: systemImage)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private func save() {
        store.updateCaption(id: entry.id, caption: caption, detail: detail)
    }
}

private struct ShareURLItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct PreviewImageItem: Identifiable {
    let id = UUID()
    let image: UIImage
    let title: String
}

// MARK: - Full-screen image preview

/// A full-screen, pinch-to-zoom / drag preview of a mosaic or its source photo.
private struct MosaicImagePreviewView: View {
    let image: UIImage
    let title: String
    @Environment(\.dismiss) private var dismiss

    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var drag: CGSize = .zero

    private let minScale: CGFloat = 1
    private let maxScale: CGFloat = 5

    var body: some View {
        NavigationStack {
            GeometryReader { _ in
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .scaleEffect(scale * pinch)
                    .offset(x: offset.width + drag.width, y: offset.height + drag.height)
                    .gesture(magnification)
                    .simultaneousGesture(dragGesture)
                    .onTapGesture(count: 2, perform: toggleZoom)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.done) { dismiss() }
                }
            }
        }
    }

    private var magnification: some Gesture {
        MagnificationGesture()
            .updating($pinch) { value, state, _ in state = value }
            .onEnded { value in
                scale = min(max(scale * value, minScale), maxScale)
                if scale == minScale { offset = .zero }
            }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .updating($drag) { value, state, _ in
                if scale > minScale { state = value.translation }
            }
            .onEnded { value in
                guard scale > minScale else { return }
                offset.width += value.translation.width
                offset.height += value.translation.height
            }
    }

    private func toggleZoom() {
        withAnimation(.easeInOut(duration: 0.2)) {
            if scale > minScale {
                scale = minScale
                offset = .zero
            } else {
                scale = 2.5
            }
        }
    }
}
