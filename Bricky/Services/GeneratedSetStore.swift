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

    /// Save a new set (most-recent first). Deduplicates by id. When
    /// `sourceImages` are provided (photo/scan flows) they are stored alongside
    /// the set — a single photo, the four angle photos, or the four video-sweep
    /// frames actually used for the 3D model — so history shows exactly what was
    /// captured next to what was built.
    func save(_ set: GeneratedLegoSet, sourceImages: [UIImage] = []) {
        sets.removeAll { $0.id == set.id }
        sets.insert(set, at: 0)
        if !sourceImages.isEmpty {
            writeSourceImages(sourceImages, for: set.id)
        }
        if sets.count > maxStored {
            let dropped = sets.suffix(from: maxStored)
            for old in dropped { removeSourceImages(for: old.id) }
            sets = Array(sets.prefix(maxStored))
        }
        persist()
    }

    func delete(_ set: GeneratedLegoSet) {
        sets.removeAll { $0.id == set.id }
        removeSourceImages(for: set.id)
        persist()
    }

    func delete(at offsets: IndexSet) {
        for index in offsets where sets.indices.contains(index) {
            removeSourceImages(for: sets[index].id)
        }
        sets.remove(atOffsets: offsets)
        persist()
    }

    func contains(_ id: UUID) -> Bool {
        sets.contains { $0.id == id }
    }

    /// The first original captured image for a set, if any (thumbnail use).
    func sourceImage(for id: UUID) -> UIImage? {
        sourceImages(for: id).first
    }

    /// All original captured images for a set (1 photo, or the 4 angle photos /
    /// video-sweep frames used to build the 3D model), in capture order.
    func sourceImages(for id: UUID) -> [UIImage] {
        var images: [UIImage] = []
        var index = 0
        while let image = UIImage(contentsOfFile: imageURL(for: id, index: index).path) {
            images.append(image)
            index += 1
            if index > maxSourceImages { break }
        }
        return images
    }

    // MARK: - Source images

    private let maxSourceImages = 4

    private func imageURL(for id: UUID, index: Int) -> URL {
        imagesDir.appendingPathComponent("\(id.uuidString)-\(index).jpg")
    }

    private func writeSourceImages(_ images: [UIImage], for id: UUID) {
        // Clear any previous frames first so a re-save can't leave stale ones.
        removeSourceImages(for: id)
        for (index, image) in images.prefix(maxSourceImages).enumerated() {
            guard let data = image.jpegData(compressionQuality: 0.8) else { continue }
            try? data.write(to: imageURL(for: id, index: index), options: .atomic)
        }
    }

    private func removeSourceImages(for id: UUID) {
        for index in 0...maxSourceImages {
            try? FileManager.default.removeItem(at: imageURL(for: id, index: index))
        }
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
