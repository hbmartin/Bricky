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

/// Whether a transport still has transfers in flight for a manifest.
enum DeliveryStatus: Equatable, Sendable {
    case idle
    /// Transfers a previous launch started are still running; the manager
    /// re-attaches to them instead of offering a fresh download.
    case transferring
}

/// The transport that puts a verified model on disk. A seam so the
/// foreground downloader can give way to a background session (and later
/// Background Assets) without the manager's admission logic changing.
/// Every implementation publishes a file only after its size and SHA-256
/// verify.
protocol ModelDelivery: Sendable {
    /// Delivers every asset, reporting overall progress in 0...1. Started
    /// only from the foreground; `allowsCellular` is the user's preference.
    func deliver(
        _ manifest: ModelManifest,
        allowsCellular: Bool,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws
    /// Deletes the revision's files, partial downloads included.
    func remove(_ manifest: ModelManifest) async throws
    /// Verifies and publishes whatever the transport finished while the app
    /// was away. Foreground only.
    func reconcile(_ manifest: ModelManifest) async -> DeliveryStatus
}

/// Sequential, resumable, foreground downloads through
/// `VerifiedAssetDownloader`. The model now arrives through
/// `BackgroundURLSessionDelivery`; this stays as the fallback transport and
/// the shape the part pack still uses.
struct ForegroundVerifiedDelivery: ModelDelivery {
    let downloader: VerifiedAssetDownloader

    init(downloader: VerifiedAssetDownloader = VerifiedAssetDownloader()) {
        self.downloader = downloader
    }

    func deliver(
        _ manifest: ModelManifest,
        allowsCellular: Bool,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws {
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

    /// Nothing outlives the foreground here: a cancelled download leaves
    /// only a `.partial` file, which the next `deliver` resumes.
    func reconcile(_ manifest: ModelManifest) async -> DeliveryStatus { .idle }
}
