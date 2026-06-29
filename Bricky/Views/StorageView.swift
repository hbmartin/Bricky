import SwiftUI

/// View for managing storage bins and assigning pieces to bins.
struct StorageView: View {
    @StateObject private var binStore = StorageBinStore.shared
    @StateObject private var inventoryStore = InventoryStore.shared
    @State private var showCreateBin = false
    @State private var newBinName = ""
    @State private var newBinColor = "Blue"
    @State private var newBinLocation = ""
    @State private var editingBin: StorageBin?
    @State private var showDeleteConfirmation = false
    @State private var binToDelete: UUID?

    private let binColors = ["Red", "Blue", "Green", "Yellow", "Orange", "Gray", "White", "Brown", "Purple", "Pink"]

    var body: some View {
        List {
            if binStore.bins.isEmpty {
                emptyState
            } else {
                ForEach(binStore.bins) { bin in
                    NavigationLink(value: bin) {
                        binRow(bin)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            binToDelete = bin.id
                            showDeleteConfirmation = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            editingBin = bin
                            newBinName = bin.name
                            newBinColor = bin.color
                            newBinLocation = bin.location
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(Color.blue)
                    }
                }
            }
        }
        .navigationTitle("Storage Bins")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    newBinName = ""
                    newBinColor = "Blue"
                    newBinLocation = ""
                    showCreateBin = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .navigationDestination(for: StorageBin.self) { bin in
            BinDetailView(binId: bin.id)
        }
        .alert("New Storage Bin", isPresented: $showCreateBin) {
            TextField("Bin Name", text: $newBinName)
            TextField("Location (optional)", text: $newBinLocation)
            Button("Create") {
                let name = newBinName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    _ = binStore.createBin(name: name, color: newBinColor, location: newBinLocation)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Edit Bin", isPresented: Binding(
            get: { editingBin != nil },
            set: { if !$0 { editingBin = nil } }
        )) {
            TextField("Name", text: $newBinName)
            TextField("Location", text: $newBinLocation)
            Button("Save") {
                if let bin = editingBin {
                    binStore.updateBin(id: bin.id, name: newBinName, location: newBinLocation)
                }
                editingBin = nil
            }
            Button("Cancel", role: .cancel) { editingBin = nil }
        }
        .confirmationDialog("Delete Bin?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let id = binToDelete {
                    binStore.deleteBin(id: id)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove the bin. Pieces will not be deleted from your inventory.")
        }
    }

    // MARK: - Bin Row

    private func binRow(_ bin: StorageBin) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6)
                .fill(binDisplayColor(bin.color))
                .frame(width: 32, height: 32)
                .overlay(
                    Image(systemName: "tray.fill")
                        .font(.caption)
                        .foregroundStyle(.white)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(bin.name)
                    .font(.subheadline)
                    .fontWeight(.medium)

                HStack(spacing: 4) {
                    if !bin.location.isEmpty {
                        Text(bin.location)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("\(bin.pieceIds.count) pieces")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: "tray")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("No Storage Bins")
                    .font(.headline)
                Text("Create bins to organize where you store your LEGO pieces.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    showCreateBin = true
                } label: {
                    Label("Create First Bin", systemImage: "plus")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.blue)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        }
    }

    private func binDisplayColor(_ name: String) -> Color {
        switch name.lowercased() {
        case "red": return Color.legoRed
        case "blue": return Color.legoBlue
        case "green": return Color.legoGreen
        case "yellow": return Color.legoYellow
        case "orange": return Color.legoOrange
        case "gray": return .gray
        case "white": return .white.opacity(0.6)
        case "brown": return .brown
        case "purple": return .purple
        case "pink": return .pink
        default: return Color.legoBlue
        }
    }
}

// MARK: - Bin Detail View

struct BinDetailView: View {
    let binId: UUID
    @StateObject private var binStore = StorageBinStore.shared
    @StateObject private var inventoryStore = InventoryStore.shared
    @State private var showAssignSheet = false
    @State private var showImportScan = false

    private var bin: StorageBin? {
        binStore.bin(forId: binId)
    }

    private var assignedPieces: [InventoryStore.InventoryPiece] {
        guard let bin, let inventory = inventoryStore.activeInventory else { return [] }
        return inventory.pieces.filter { bin.pieceIds.contains($0.id) }
    }

    var body: some View {
        List {
            if let bin {
                // Info
                Section {
                    if !bin.location.isEmpty {
                        LabeledContent("Location", value: bin.location)
                    }
                    LabeledContent("Pieces", value: "\(bin.pieceIds.count)")
                    LabeledContent("Created", value: bin.createdAt.formatted(date: .abbreviated, time: .omitted))
                } header: {
                    Text("Details")
                }

                // Pieces
                Section {
                    if assignedPieces.isEmpty {
                        Text("No pieces assigned to this bin")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    } else {
                        ForEach(assignedPieces) { piece in
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.legoColor(piece.pieceColor))
                                    .frame(width: 24, height: 24)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(piece.name)
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    Text("\(piece.dimensions.displayString) · \(piece.color)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Text("×\(piece.quantity)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    binStore.removePiece(piece.id, fromBin: binId)
                                } label: {
                                    Label("Remove", systemImage: "minus.circle")
                                }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Pieces")
                        Spacer()
                        Button {
                            showImportScan = true
                        } label: {
                            Label("Import Scan", systemImage: "square.and.arrow.down")
                                .font(.caption)
                        }
                        Button {
                            showAssignSheet = true
                        } label: {
                            Label("Add", systemImage: "plus")
                                .font(.caption)
                        }
                    }
                }
            }
        }
        .navigationTitle(bin?.name ?? "Bin")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAssignSheet) {
            AssignPieceView(binId: binId)
        }
        .sheet(isPresented: $showImportScan) {
            ImportScanIntoBinView(binId: binId)
        }
    }
}

// MARK: - Assign Piece View

struct AssignPieceView: View {
    let binId: UUID
    @StateObject private var binStore = StorageBinStore.shared
    @StateObject private var inventoryStore = InventoryStore.shared
    @State private var searchText = ""
    @Environment(\.dismiss) private var dismiss

    private var availablePieces: [InventoryStore.InventoryPiece] {
        guard let inventory = inventoryStore.activeInventory,
              let bin = binStore.bin(forId: binId) else { return [] }
        let assigned = Set(bin.pieceIds)
        var pieces = inventory.pieces.filter { !assigned.contains($0.id) }
        if !searchText.isEmpty {
            let lower = searchText.lowercased()
            pieces = pieces.filter {
                $0.name.lowercased().contains(lower) ||
                $0.partNumber.lowercased().contains(lower) ||
                $0.color.lowercased().contains(lower)
            }
        }
        return pieces
    }

    var body: some View {
        NavigationStack {
            List {
                if availablePieces.isEmpty {
                    ContentUnavailableView("No Pieces Available",
                                           systemImage: "cube",
                                           description: Text("All pieces are already assigned or no active inventory."))
                } else {
                    ForEach(availablePieces) { piece in
                        Button {
                            binStore.assignPiece(piece.id, toBin: binId)
                        } label: {
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.legoColor(piece.pieceColor))
                                    .frame(width: 24, height: 24)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(piece.name)
                                        .font(.subheadline)
                                    Text("\(piece.partNumber) · \(piece.color)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Image(systemName: "plus.circle")
                                    .foregroundStyle(Color.blue)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search pieces")
            .navigationTitle("Add Pieces")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Import Scan Into Bin

/// Imports a whole brick scan "into" a bin — like adding a roll of photos to an
/// album. Each scan's identified pieces are added to the active inventory (one
/// is created if none exists) and assigned to the bin in a single tap.
struct ImportScanIntoBinView: View {
    let binId: UUID
    @StateObject private var history = ScanHistoryStore.shared
    @StateObject private var binStore = StorageBinStore.shared
    @StateObject private var inventoryStore = InventoryStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if history.entries.isEmpty {
                    ContentUnavailableView(
                        "No Scans Yet",
                        systemImage: "camera.viewfinder",
                        description: Text("Scan a pile of bricks first, then import it into this bin.")
                    )
                } else {
                    ForEach(history.entries) { entry in
                        Button {
                            importScan(entry)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "tray.full")
                                    .foregroundStyle(Color.legoOrangeLabel)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                                        .font(.subheadline).fontWeight(.medium)
                                    Text("\(entry.totalPiecesFound) pieces · \(entry.uniquePieceCount) unique")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "square.and.arrow.down")
                                    .foregroundStyle(Color.blue)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Import a Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    /// Add the scan's pieces to the active inventory and associate them with the bin.
    private func importScan(_ entry: ScanHistoryStore.HistoryEntry) {
        let invId = inventoryStore.activeInventoryId
            ?? inventoryStore.createInventory(name: "My Inventory")
        let newPieces = entry.pieces.map { p in
            InventoryStore.InventoryPiece(
                partNumber: p.partNumber, name: p.name, category: p.category,
                color: p.color, quantity: p.quantity, dimensions: p.dimensions
            )
        }
        inventoryStore.addPieces(newPieces, to: invId)
        // addPieces merges by part+color, so map back to the stored ids.
        let keys = Set(entry.pieces.map { "\($0.partNumber)|\($0.color.rawValue)" })
        let storedIds = (inventoryStore.activeInventory?.pieces ?? [])
            .filter { keys.contains("\($0.partNumber)|\($0.color)") }
            .map(\.id)
        binStore.assignPieces(storedIds, toBin: binId)
    }
}

