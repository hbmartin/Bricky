import SwiftUI
import UIKit

/// Shared result screen for both Set Forge flows. Shows a rotatable 3D preview
/// of the generated brick model, key stats, an optional "buildable with your
/// inventory" match, the full parts list, step-by-step instructions, and export
/// (LDraw) / share. The set is already saved to `GeneratedSetStore`.
struct GeneratedSetView: View {
    let set: GeneratedLegoSet

    @StateObject private var inventoryStore = InventoryStore.shared
    @State private var shareItem: ShareItem?
    @State private var showInstructions = false
    @Environment(\.dismiss) private var dismiss

    private struct ShareItem: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    private var inventoryMatch: Double? {
        let owned = inventoryStore.activePiecesAsLegoPieces()
        guard !owned.isEmpty else { return nil }
        return set.asLegoProject().matchPercentage(with: owned)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                preview
                statsRow
                if let match = inventoryMatch {
                    inventoryChip(match)
                }
                actionButtons
                partsSection
            }
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(set.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showInstructions) {
            InstructionStepsView(set: set)
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
    }

    // MARK: - Preview

    private var preview: some View {
        BrickModelSceneView(bricks: set.bricks)
            .frame(height: 300)
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(
                    colors: [Color(.secondarySystemGroupedBackground), Color(.tertiarySystemGroupedBackground)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(alignment: .bottomTrailing) {
                Text("Drag to rotate")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .background(.thinMaterial, in: Capsule())
                    .padding(8)
            }
    }

    // MARK: - Stats

    private var statsRow: some View {
        HStack(spacing: 12) {
            statCard(value: "\(set.brickCount)", label: "Bricks", icon: "square.stack.3d.up.fill")
            statCard(value: "\(set.layerCount)", label: "Layers", icon: "square.3.layers.3d")
            statCard(value: set.difficulty.rawValue, label: "Difficulty", icon: "chart.bar.fill")
        }
    }

    private func statCard(value: String, label: String, icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.legoBlue)
            Text(value)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
    }

    private func inventoryChip(_ match: Double) -> some View {
        let percent = Int((match * 100).rounded())
        return HStack(spacing: 10) {
            Image(systemName: percent >= 100 ? "checkmark.seal.fill" : "tray.full.fill")
                .foregroundStyle(percent >= 100 ? .green : Color.legoOrange)
            Text(percent >= 100
                 ? "You have all the pieces to build this!"
                 : "You already own \(percent)% of the pieces")
                .font(.subheadline)
            Spacer()
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
    }

    // MARK: - Actions

    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button {
                showInstructions = true
            } label: {
                Label("View Building Instructions", systemImage: "list.number")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.legoBlue)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }

            Button {
                exportLDraw()
            } label: {
                Label("Export & Share (LDraw)", systemImage: "square.and.arrow.up")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
            }

            Button {
                exportSTL()
            } label: {
                Label("Export for 3D Printing (STL)", systemImage: "cube.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
            }
        }
    }

    // MARK: - Parts

    private var partsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Parts List")
                .font(.headline)
            Text("\(set.parts.count) unique parts · \(set.brickCount) bricks total")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(set.parts) { part in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(hex: part.color.hexColor))
                        .frame(width: 22, height: 22)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.black.opacity(0.15)))
                    Text(part.name)
                        .font(.subheadline)
                    Spacer()
                    Text("×\(part.quantity)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
                Divider()
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
    }

    // MARK: - Export

    private func exportLDraw() {
        let dir = FileManager.default.temporaryDirectory
        let safeName = set.name.replacingOccurrences(of: "/", with: "-")
        let url = dir.appendingPathComponent("\(safeName).ldr")
        do {
            try set.ldrText.write(to: url, atomically: true, encoding: .utf8)
            shareItem = ShareItem(url: url)
        } catch {
            // Non-fatal; simply don't present the share sheet.
        }
    }

    private func exportSTL() {
        let dir = FileManager.default.temporaryDirectory
        let safeName = set.name.replacingOccurrences(of: "/", with: "-")
        let url = dir.appendingPathComponent("\(safeName).stl")
        do {
            try SetForgeSTLExporter.export(set.bricks).write(to: url, options: .atomic)
            shareItem = ShareItem(url: url)
        } catch {
            // Non-fatal; simply don't present the share sheet.
        }
    }
}

/// Simple step-by-step instructions list for a generated set.
private struct InstructionStepsView: View {
    let set: GeneratedLegoSet
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(set.steps) { step in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Step \(step.stepNumber)")
                            .font(.headline)
                            .foregroundStyle(Color.legoBlue)
                        Text(step.instruction)
                            .font(.subheadline)
                        if !step.piecesUsed.isEmpty {
                            Text(step.piecesUsed)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let tip = step.tip {
                            Label(tip, systemImage: "lightbulb.fill")
                                .font(.caption)
                                .foregroundStyle(Color.legoOrange)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Instructions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
