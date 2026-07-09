import Foundation
import Combine
import UIKit

/// Persists Set Forge creations to disk (JSON in Application Support) so users
/// can revisit, rebuild, and share their generated sets. Offline-first; no
/// network. Mirrors the app's other on-device stores.
@MainActor
final class GeneratedSetStore: ObservableObject {
    static let shared = GeneratedSetStore()

    @Published private(set) var sets: [GeneratedLegoSet] = []

    private let fileURL: URL
    private let imagesDir: URL
    private let maxStored = 100

    init(filename: String = "generated_sets.json") {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent(filename)
        self.imagesDir = dir.appendingPathComponent("generated_set_images", isDirectory: true)
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        load()
    }

    /// Save a new set (most-recent first). Deduplicates by id. When a
    /// `sourceImage` is provided (photo/scan flows) it is stored alongside the
    /// set so history shows what was scanned next to what was built.
    func save(_ set: GeneratedLegoSet, sourceImage: UIImage? = nil) {
        sets.removeAll { $0.id == set.id }
        sets.insert(set, at: 0)
        if let sourceImage {
            writeSourceImage(sourceImage, for: set.id)
        }
        if sets.count > maxStored {
            let dropped = sets.suffix(from: maxStored)
            for old in dropped { removeSourceImage(for: old.id) }
            sets = Array(sets.prefix(maxStored))
        }
        persist()
    }

    func delete(_ set: GeneratedLegoSet) {
        sets.removeAll { $0.id == set.id }
        removeSourceImage(for: set.id)
        persist()
    }

    func delete(at offsets: IndexSet) {
        for index in offsets where sets.indices.contains(index) {
            removeSourceImage(for: sets[index].id)
        }
        sets.remove(atOffsets: offsets)
        persist()
    }

    func contains(_ id: UUID) -> Bool {
        sets.contains { $0.id == id }
    }

    /// The original scanned/photographed image for a set, if one was saved.
    func sourceImage(for id: UUID) -> UIImage? {
        UIImage(contentsOfFile: imageURL(for: id).path)
    }

    // MARK: - Source images

    private func imageURL(for id: UUID) -> URL {
        imagesDir.appendingPathComponent("\(id.uuidString).jpg")
    }

    private func writeSourceImage(_ image: UIImage, for id: UUID) {
        guard let data = image.jpegData(compressionQuality: 0.8) else { return }
        try? data.write(to: imageURL(for: id), options: .atomic)
    }

    private func removeSourceImage(for id: UUID) {
        try? FileManager.default.removeItem(at: imageURL(for: id))
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? JSONDecoder().decode([GeneratedLegoSet].self, from: data) {
            sets = decoded
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(sets) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
