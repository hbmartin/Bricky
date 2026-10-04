import CryptoKit
import Foundation

/// Resolves a model directory the pinned loader can actually load.
///
/// The pinned revision `mlx-community/Qwen3-VL-4B-Instruct-4bit@2fd8dac…`
/// ships every weight in one `model.safetensors`, but also a
/// `model.safetensors.index.json` left over from the unquantized upstream
/// that names two shards the repository does not contain. The pinned
/// mlx-swift-lm loader prefers an index whenever one exists
/// (`safetensorWeightURLs`), so loading fails with "Failed to open file
/// model-00001-of-00002.safetensors" — on device and in the harness alike.
///
/// When the index names a file that is absent, this returns a directory of
/// symlinks to every other entry, so the loader falls back to enumerating
/// `*.safetensors`. The user's files are never modified, and a directory
/// whose index is consistent is returned unchanged.
enum LoadableModelDirectory {
    static let indexFilename = "model.safetensors.index.json"

    private struct SafetensorsIndex: Decodable {
        let weightMap: [String: String]
        enum CodingKeys: String, CodingKey { case weightMap = "weight_map" }
    }

    static func resolve(_ directory: URL, fileManager: FileManager = .default) throws -> URL {
        let index = directory.appendingPathComponent(indexFilename)
        guard fileManager.fileExists(atPath: index.path),
              let data = try? Data(contentsOf: index),
              let decoded = try? JSONDecoder().decode(SafetensorsIndex.self, from: data) else {
            return directory
        }
        let missing = Set(decoded.weightMap.values).filter {
            !fileManager.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
        guard !missing.isEmpty else { return directory }

        let digest = SHA256.hash(data: Data(directory.standardizedFileURL.path.utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        let shadow = fileManager.temporaryDirectory
            .appendingPathComponent("bricky-loadable-model-\(digest)", isDirectory: true)
        try? fileManager.removeItem(at: shadow)
        try fileManager.createDirectory(at: shadow, withIntermediateDirectories: true)
        for name in try fileManager.contentsOfDirectory(atPath: directory.path) where name != indexFilename {
            try fileManager.createSymbolicLink(
                at: shadow.appendingPathComponent(name),
                withDestinationURL: directory.appendingPathComponent(name)
            )
        }
        return shadow
    }
}
