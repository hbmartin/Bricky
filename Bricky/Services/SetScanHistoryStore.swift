import Foundation
import UIKit

/// Persists past LEGO **set** identifications so the user can revisit which set
/// a scanned model was matched to — mirroring `MosaicScanHistoryStore` and
/// `MinifigureScanHistoryStore`.
///
/// Each entry captures the scanned photo thumbnail and the ranked candidate
/// sets returned by the identifier. Thumbnails live under
/// `Documents/setScanHistory/`; the metadata is a single JSON file.
@MainActor
final class SetScanHistoryStore: ObservableObject {
    static let shared = SetScanHistoryStore()

    struct ScanEntry: Identifiable, Codable {
        let id: UUID
        let date: Date
        let candidates: [IdentifiedSet]

        var thumbnailFilename: String { "\(id.uuidString)-thumb.jpg" }

        /// The best (first) candidate's display name, for list rows.
        var topName: String { candidates.first?.displayName ?? "Unknown set" }
        var topConfidence: Double { candidates.first?.confidence ?? 0 }
        var isVerified: Bool { candidates.first?.isVerified ?? false }

        init(id: UUID, date: Date, candidates: [IdentifiedSet]) {
            self.id = id
            self.date = date
            self.candidates = candidates
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
        jsonURL = docs.appendingPathComponent("setScanHistory.json")
        filesDir = docs.appendingPathComponent("setScanHistory", isDirectory: true)
        try? FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)
        load()
    }

    // MARK: - Public API

    @discardableResult
    func record(candidates: [IdentifiedSet], sourceImage: UIImage?) -> UUID {
        let entry = ScanEntry(id: UUID(), date: Date(), candidates: candidates)
        if let sourceImage {
            writeImage(sourceImage, to: filesDir.appendingPathComponent(entry.thumbnailFilename))
        }
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            let dropped = Array(entries[maxEntries...])
            entries = Array(entries.prefix(maxEntries))
            for old in dropped { deleteFiles(for: old) }
        }
        save()
        return entry.id
    }

    func thumbnail(for entry: ScanEntry) -> UIImage? {
        loadImage(filesDir.appendingPathComponent(entry.thumbnailFilename))
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

    func reload() { load() }

    // MARK: - Persistence

    private func deleteFiles(for entry: ScanEntry) {
        try? FileManager.default.removeItem(at: filesDir.appendingPathComponent(entry.thumbnailFilename))
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
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}
