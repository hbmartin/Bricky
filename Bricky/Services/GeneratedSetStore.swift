import Foundation
import Combine

/// Persists Set Forge creations to disk (JSON in Application Support) so users
/// can revisit, rebuild, and share their generated sets. Offline-first; no
/// network. Mirrors the app's other on-device stores.
@MainActor
final class GeneratedSetStore: ObservableObject {
    static let shared = GeneratedSetStore()

    @Published private(set) var sets: [GeneratedLegoSet] = []

    private let fileURL: URL
    private let maxStored = 100

    init(filename: String = "generated_sets.json") {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent(filename)
        load()
    }

    /// Save a new set (most-recent first). Deduplicates by id.
    func save(_ set: GeneratedLegoSet) {
        sets.removeAll { $0.id == set.id }
        sets.insert(set, at: 0)
        if sets.count > maxStored {
            sets = Array(sets.prefix(maxStored))
        }
        persist()
    }

    func delete(_ set: GeneratedLegoSet) {
        sets.removeAll { $0.id == set.id }
        persist()
    }

    func delete(at offsets: IndexSet) {
        sets.remove(atOffsets: offsets)
        persist()
    }

    func contains(_ id: UUID) -> Bool {
        sets.contains { $0.id == id }
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
