import Foundation

/// What to deliver: one immutable model revision and where it lives.
struct ModelManifest: Sendable, Hashable {
    let modelID: String
    let revision: String
    let assets: [RecoveryModelManager.Asset]
    let directory: URL

    var totalBytes: Int64 { assets.reduce(0) { $0 + $1.bytes } }

    func remoteURL(for asset: RecoveryModelManager.Asset) -> URL {
        let encodedPath = asset.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? asset.path
        return URL(string: "https://huggingface.co/\(modelID)/resolve/\(revision)/\(encodedPath)?download=true")!
    }
}

/// The transport that puts a verified model on disk. A seam so the
/// foreground downloader can give way to a background session (and later
/// Background Assets) without the manager's admission logic changing.
/// Every implementation publishes a file only after its size and SHA-256
/// verify.
protocol ModelDelivery: Sendable {
    /// Delivers every asset, reporting overall progress in 0...1.
    func deliver(_ manifest: ModelManifest, progress: @escaping @Sendable (Double) async -> Void) async throws
    /// Deletes the revision's files, partial downloads included.
    func remove(_ manifest: ModelManifest) async throws
}

/// Today's transport: sequential, resumable, foreground downloads through
/// `VerifiedAssetDownloader`, moved here from the manager unchanged.
struct ForegroundVerifiedDelivery: ModelDelivery {
    let downloader: VerifiedAssetDownloader

    init(downloader: VerifiedAssetDownloader = VerifiedAssetDownloader()) {
        self.downloader = downloader
    }

    func deliver(_ manifest: ModelManifest, progress: @escaping @Sendable (Double) async -> Void) async throws {
        try FileManager.default.createDirectory(at: manifest.directory, withIntermediateDirectories: true)
        let total = Double(manifest.totalBytes)
        var completed: Int64 = 0
        for asset in manifest.assets {
            try Task.checkCancellation()
            let completedBeforeAsset = completed
            try await downloader.download(
                from: manifest.remoteURL(for: asset),
                to: manifest.directory.appendingPathComponent(asset.path),
                expectedBytes: asset.bytes,
                expectedSHA256: asset.sha256
            ) { fileProgress in
                await progress(min(1, (Double(completedBeforeAsset) + fileProgress * Double(asset.bytes)) / total))
            }
            completed += asset.bytes
        }
    }

    func remove(_ manifest: ModelManifest) async throws {
        guard FileManager.default.fileExists(atPath: manifest.directory.path) else { return }
        try FileManager.default.removeItem(at: manifest.directory)
    }
}
