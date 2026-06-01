import Foundation
import UIKit

/// Persists generated LEGO mosaics so users can revisit, re-share, and re-caption
/// past builds — mirroring `MinifigureScanHistoryStore`.
///
/// Each entry captures:
/// - The source photo and the rendered mosaic thumbnail
/// - The snapped grid size, brick/stud counts, and aggregated parts list
/// - An editable caption and description
/// - The exportable LDraw model and instructions PDF (copied locally so they
///   survive after the temporary generation directory is gone)
///
/// Images and artifacts are stored under `Documents/mosaicScanHistory/`.
@MainActor
final class MosaicScanHistoryStore: ObservableObject {
    static let shared = MosaicScanHistoryStore()

    struct ScanEntry: Identifiable, Codable {
        let id: UUID
        let date: Date
        var caption: String
        var detail: String
        let gridWidth: Int
        let gridHeight: Int
        let brickCount: Int
        let studCount: Int
        let totalParts: Int
        let parts: [MosaicPartLine]
        let presetLabel: String

        var sourceImageFilename: String { "\(id.uuidString)-source.jpg" }
        var thumbnailFilename: String { "\(id.uuidString)-thumb.jpg" }
        var ldrFilename: String { "\(id.uuidString).ldr" }
        var pdfFilename: String { "\(id.uuidString).pdf" }

        // Backward-compatible decoding so future fields can be added safely.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            date = try c.decode(Date.self, forKey: .date)
            caption = (try? c.decode(String.self, forKey: .caption)) ?? ""
            detail = (try? c.decode(String.self, forKey: .detail)) ?? ""
            gridWidth = try c.decode(Int.self, forKey: .gridWidth)
            gridHeight = try c.decode(Int.self, forKey: .gridHeight)
            brickCount = try c.decode(Int.self, forKey: .brickCount)
            studCount = try c.decode(Int.self, forKey: .studCount)
            totalParts = try c.decode(Int.self, forKey: .totalParts)
            parts = (try? c.decode([MosaicPartLine].self, forKey: .parts)) ?? []
            presetLabel = (try? c.decode(String.self, forKey: .presetLabel)) ?? ""
        }

        init(id: UUID, date: Date, caption: String, detail: String,
             gridWidth: Int, gridHeight: Int, brickCount: Int, studCount: Int,
             totalParts: Int, parts: [MosaicPartLine], presetLabel: String) {
            self.id = id
            self.date = date
            self.caption = caption
            self.detail = detail
            self.gridWidth = gridWidth
            self.gridHeight = gridHeight
            self.brickCount = brickCount
            self.studCount = studCount
            self.totalParts = totalParts
            self.parts = parts
            self.presetLabel = presetLabel
        }
    }

    @Published private(set) var entries: [ScanEntry] = []

    private let maxEntries = 100
    private let jsonURL: URL
    private let filesDir: URL
    private let jpegQuality: CGFloat = 0.8
    private let maxImageEdge: CGFloat = 1024

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        jsonURL = docs.appendingPathComponent("mosaicScanHistory.json")
        filesDir = docs.appendingPathComponent("mosaicScanHistory", isDirectory: true)
        try? FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)
        load()
    }

    // MARK: - Public API

    /// Record a finished mosaic. Returns the new entry's id so the caller can
    /// later update its caption/description.
    @discardableResult
    func record(
        gridWidth: Int,
        gridHeight: Int,
        brickCount: Int,
        studCount: Int,
        totalParts: Int,
        parts: [MosaicPartLine],
        presetLabel: String,
        sourceImage: UIImage?,
        thumbnail: UIImage?,
        ldrText: String,
        pdfData: Data,
        caption: String = "",
        detail: String = ""
    ) -> UUID {
        let entry = ScanEntry(
            id: UUID(),
            date: Date(),
            caption: caption,
            detail: detail,
            gridWidth: gridWidth,
            gridHeight: gridHeight,
            brickCount: brickCount,
            studCount: studCount,
            totalParts: totalParts,
            parts: parts,
            presetLabel: presetLabel
        )

        if let sourceImage {
            writeImage(sourceImage, to: filesDir.appendingPathComponent(entry.sourceImageFilename))
        }
        if let thumbnail {
            writeImage(thumbnail, to: filesDir.appendingPathComponent(entry.thumbnailFilename))
        }
        try? Data(ldrText.utf8).write(
            to: filesDir.appendingPathComponent(entry.ldrFilename), options: .atomic
        )
        try? pdfData.write(
            to: filesDir.appendingPathComponent(entry.pdfFilename), options: .atomic
        )

        entries.insert(entry, at: 0)

        if entries.count > maxEntries {
            let dropped = Array(entries[maxEntries...])
            entries = Array(entries.prefix(maxEntries))
            for old in dropped { deleteFiles(for: old) }
        }

        save()
        return entry.id
    }

    /// Update the editable caption and description for an existing entry.
    func updateCaption(id: UUID, caption: String, detail: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].caption = caption
        entries[index].detail = detail
        save()
    }

    func sourceImage(for entry: ScanEntry) -> UIImage? {
        loadImage(filesDir.appendingPathComponent(entry.sourceImageFilename))
    }

    func thumbnail(for entry: ScanEntry) -> UIImage? {
        loadImage(filesDir.appendingPathComponent(entry.thumbnailFilename))
    }

    /// On-disk URL for the LDraw model, or `nil` if missing.
    func ldrURL(for entry: ScanEntry) -> URL? {
        let url = filesDir.appendingPathComponent(entry.ldrFilename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// On-disk URL for the instructions PDF, or `nil` if missing.
    func pdfURL(for entry: ScanEntry) -> URL? {
        let url = filesDir.appendingPathComponent(entry.pdfFilename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func delete(_ entry: ScanEntry) {
        entries.removeAll { $0.id == entry.id }
        deleteFiles(for: entry)
        save()
    }

    func delete(_ ids: Set<UUID>) {
        let toRemove = entries.filter { ids.contains($0.id) }
        for entry in toRemove { deleteFiles(for: entry) }
        entries.removeAll { ids.contains($0.id) }
        save()
    }

    func deleteAll() {
        for entry in entries { deleteFiles(for: entry) }
        entries.removeAll()
        save()
    }

    /// Re-read from disk. Used by pull-to-refresh.
    func reload() {
        load()
    }

    // MARK: - Persistence

    private func deleteFiles(for entry: ScanEntry) {
        let fm = FileManager.default
        for name in [entry.sourceImageFilename, entry.thumbnailFilename, entry.ldrFilename, entry.pdfFilename] {
            try? fm.removeItem(at: filesDir.appendingPathComponent(name))
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: jsonURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: jsonURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([ScanEntry].self, from: data)) ?? []
    }

    // MARK: - Image helpers

    private func writeImage(_ image: UIImage, to url: URL) {
        let downscaled = Self.downscale(image, maxEdge: maxImageEdge)
        if let data = downscaled.jpegData(compressionQuality: jpegQuality) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func loadImage(_ url: URL) -> UIImage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    private static func downscale(_ image: UIImage, maxEdge: CGFloat) -> UIImage {
        let size = image.size
        let longestEdge = max(size.width, size.height)
        guard longestEdge > maxEdge else { return image }
        let scale = maxEdge / longestEdge
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
