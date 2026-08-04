import ARKit
import Foundation
import Network
import RecoveryMLX
import UIKit

@MainActor
final class RecoveryModelManager: ObservableObject {
    nonisolated static let modelID = "mlx-community/Qwen3-VL-4B-Instruct-4bit"
    nonisolated static let revision = "2fd8dacbdb8f1e54b8c005f081ec5bf79c56376b"
    // 🟡 RECONSTRUCTED: physical-device profiling must replace this conservative
    // release floor with measured worst-case peak + 25% before App Store release.
    nonisolated static let minimumAvailableMemory: UInt64 = 5_500_000_000

    struct Asset: Sendable {
        let path: String
        let bytes: Int64
        let sha256: String
    }

    static let assets: [Asset] = [
        .init(path: "added_tokens.json", bytes: 707, sha256: "c0284b582e14987fbd3d5a2cb2bd139084371ed9acbae488829a1c900833c680"),
        .init(path: "chat_template.jinja", bytes: 5_292, sha256: "3636d0f0bd6bef02654cdffdc447b79cb2cef8ab02cc75267345946291a489e4"),
        .init(path: "chat_template.json", bytes: 5_502, sha256: "6f8a6a55027e3da5160105556cda5dd69f6423f1c32645f6730d32de7773d0c4"),
        .init(path: "config.json", bytes: 7_137, sha256: "07406d087dfb8a8849427a4da81bc9edd1dd942e518493629b5a983169b47820"),
        .init(path: "generation_config.json", bytes: 269, sha256: "8469742d1fce0de951c8909b26a2c0c0d8490837ce476efb114da9e0cefc4d44"),
        .init(path: "merges.txt", bytes: 1_671_853, sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
        .init(path: "model.safetensors", bytes: 3_093_767_283, sha256: "90eeb02604181dbcccd0a30a1f550a4a8928ca7dcbee4aee1449239306cfdfca"),
        .init(path: "model.safetensors.index.json", bytes: 64_742, sha256: "58a7841d7bff2548dd91577d216274a83cf1b500bc6a534b809d6c1b1707cf2b"),
        .init(path: "preprocessor_config.json", bytes: 782, sha256: "93585062a80db5e8ca038efc7726a3e6411d9db948472d81d63c6303993be8c5"),
        .init(path: "special_tokens_map.json", bytes: 613, sha256: "76862e765266b85aa9459767e33cbaf13970f327a0e88d1c65846c2ddd3a1ecd"),
        .init(path: "tokenizer.json", bytes: 11_422_654, sha256: "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"),
        .init(path: "tokenizer_config.json", bytes: 5_445, sha256: "81ec7bb9530159b326c0bef1d0b6c33d392090524014ea3f0123a3c1eb9c2af5"),
        .init(path: "video_preprocessor_config.json", bytes: 817, sha256: "59c5c9eb52182eb14c06ffb10ca9effd29adce5f238a95de23ca14a38dbd2cb1"),
        .init(path: "vocab.json", bytes: 2_776_833, sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910")
    ]

    @Published private(set) var state: ModelAdmissionState = .checking
    /// Whether the current `.rejected` state is a transient failure that a
    /// re-run of `check()` can recover from (dropped connection, cellular
    /// refusal, warm-up hiccup) as opposed to unsupported hardware.
    @Published private(set) var rejectionIsRetryable = false
    @Published var allowsCellularDownloads = false

    let runtime = MLXRecoveryRuntime()
    private let downloader = VerifiedAssetDownloader()
    private enum WorkKind { case download, warmUp }
    private var workTask: Task<Void, Never>?
    private var workKind: WorkKind?
    private var trackedInference: [UUID: Task<Void, Never>] = [:]

    var modelDirectory: URL? {
        try? InstructionModelImporter.applicationSupportRoot()
            .appendingPathComponent("RecoveryModels/Qwen3-VL-4B-Instruct-4bit/\(Self.revision)", isDirectory: true)
    }

    func check() async {
        state = .checking
        guard ARCameraManager.isSupported else {
            reject(reason: "Recovery needs a LiDAR-equipped iPhone. Guides remain available.", retryable: false)
            return
        }
        let memory = os_proc_available_memory()
        guard memory >= Self.minimumAvailableMemory else {
            reject(reason: "This device does not have enough live memory for private on-device recovery right now. Close other apps and retry, or continue with guides.", retryable: true)
            return
        }
        guard let directory = modelDirectory else {
            reject(reason: "Application Support is unavailable.", retryable: true)
            return
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var missingBytes: Int64 = 0
        for asset in Self.assets {
            let url = directory.appendingPathComponent(asset.path)
            do {
                let isValid = try await downloader.verify(
                    url,
                    expectedBytes: asset.bytes,
                    expectedSHA256: asset.sha256
                )
                if !isValid {
                    // Completed assets are published only after verification;
                    // a now-invalid destination is corrupt and not resumable.
                    try? FileManager.default.removeItem(at: url)
                    missingBytes += Self.creditedMissingBytes(expectedBytes: asset.bytes, destination: url)
                }
            } catch {
                // A thrown read or hashing failure can be transient, so keep
                // the destination. The downloader re-verifies it before
                // downloading and removes it itself if genuinely corrupt.
                missingBytes += Self.creditedMissingBytes(expectedBytes: asset.bytes, destination: url)
            }
        }
        if missingBytes == 0 {
            state = .warming
        } else {
            let available = (try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage ?? 0
            guard available >= missingBytes else {
                reject(reason: VerifiedAssetError.insufficientStorage(required: missingBytes, available: available).localizedDescription, retryable: true)
                return
            }
            state = .needsDownload(bytes: missingBytes)
        }
    }

    func download() {
        workTask?.cancel()
        workKind = .download
        workTask = Task { [weak self] in await self?.performDownload() }
    }

    func warmUpWhileARIsActive() {
        guard case .warming = state else { return }
        workTask?.cancel()
        workKind = .warmUp
        workTask = Task { [weak self] in await self?.performWarmUp() }
    }

    /// Registers an inference task started outside the manager (recovery
    /// analysis, step checks) so `cancelAndAwait()` can cancel AND drain it
    /// before the runtime unloads. The entry removes itself on completion.
    func trackInference(_ task: Task<Void, Never>) {
        let id = UUID()
        trackedInference[id] = task
        Task { [weak self] in
            await task.value
            self?.trackedInference[id] = nil
        }
    }

    func cancelAndAwait() async {
        workTask?.cancel()
        await workTask?.value
        workTask = nil
        workKind = nil
        await drainTrackedInference()
        await runtime.unload()
        if case .admitted = state { state = .warming }
    }

    /// Drains only model work during `.inactive`; an in-progress multi-GB
    /// download remains resumable unless the scene actually backgrounds.
    func suspendInferenceAndAwait() async {
        if workKind == .warmUp {
            workTask?.cancel()
            await workTask?.value
            workTask = nil
            workKind = nil
        }
        await drainTrackedInference()
        await runtime.unload()
        if case .admitted = state { state = .warming }
    }

    private func performDownload() async {
        do {
            let path = await NetworkPathProbe.current()
            if path.usesInterfaceType(.cellular), !allowsCellularDownloads {
                reject(reason: "The recovery model is about 3.1 GB. Connect to Wi‑Fi or allow cellular download, then retry.", retryable: true)
                return
            }
            guard let directory = modelDirectory else { throw CocoaError(.fileNoSuchFile) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let total = Double(Self.assets.reduce(Int64(0)) { $0 + $1.bytes })
            var completed: Int64 = 0
            for asset in Self.assets {
                try Task.checkCancellation()
                let completedBeforeAsset = completed
                let encodedPath = asset.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? asset.path
                let remote = URL(string: "https://huggingface.co/\(Self.modelID)/resolve/\(Self.revision)/\(encodedPath)?download=true")!
                try await downloader.download(
                    from: remote,
                    to: directory.appendingPathComponent(asset.path),
                    expectedBytes: asset.bytes,
                    expectedSHA256: asset.sha256
                ) { fileProgress in
                    await self.updateDownloadProgress(
                        completedBytes: completedBeforeAsset,
                        currentAssetBytes: asset.bytes,
                        fileProgress: fileProgress,
                        totalBytes: total
                    )
                }
                completed += asset.bytes
            }
            state = .warming
        } catch is CancellationError {
            // Credit already-verified assets and resumable partials so the
            // surfaced remainder reflects what the resumed download needs.
            state = .needsDownload(bytes: remainingDownloadBytes())
        } catch {
            reject(reason: error.localizedDescription, retryable: true)
        }
    }

    private func performWarmUp() async {
        do {
            guard os_proc_available_memory() >= Self.minimumAvailableMemory else {
                throw RecoveryError.insufficientMemory(
                    requiredBytes: Int64(Self.minimumAvailableMemory),
                    availableBytes: Int64(os_proc_available_memory())
                )
            }
            guard let directory = modelDirectory else { throw CocoaError(.fileNoSuchFile) }
            let board = try Self.makeWarmUpBoard(in: directory)
            // ✅ VERIFIED: the first production-shaped inference, not weight
            // loading, is the admission fit test.
            try await runtime.warmUp(imageURL: board, modelDirectory: directory)
            state = .admitted
        } catch is CancellationError {
            state = .warming
        } catch {
            await runtime.unload()
            reject(reason: "Recovery warm-up failed: \(error.localizedDescription)", retryable: true)
        }
    }

    private func reject(reason: String, retryable: Bool) {
        rejectionIsRetryable = retryable
        state = .rejected(reason: reason)
    }

    /// Total bytes still needed across all assets, crediting fully published
    /// destinations and resumable `.partial` files (statted directly; the
    /// downloader is not involved).
    private func remainingDownloadBytes() -> Int64 {
        guard let directory = modelDirectory else {
            return Self.assets.reduce(Int64(0)) { $0 + $1.bytes }
        }
        var missing: Int64 = 0
        for asset in Self.assets {
            let destination = directory.appendingPathComponent(asset.path)
            // Destinations are published only after hash verification, so a
            // full-size destination counts as complete.
            if let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init),
               size == asset.bytes {
                continue
            }
            missing += Self.creditedMissingBytes(expectedBytes: asset.bytes, destination: destination)
        }
        return missing
    }

    private func drainTrackedInference() async {
        let inference = trackedInference
        for task in inference.values { task.cancel() }
        for (id, task) in inference {
            await task.value
            trackedInference[id] = nil
        }
    }

    private static func creditedMissingBytes(expectedBytes: Int64, destination: URL) -> Int64 {
        let partial = destination.appendingPathExtension("partial")
        let partialBytes = Int64((try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        return max(0, expectedBytes - partialBytes)
    }

    private func updateDownloadProgress(
        completedBytes: Int64,
        currentAssetBytes: Int64,
        fileProgress: Double,
        totalBytes: Double
    ) {
        state = .downloading(
            progress: min(1, (Double(completedBytes) + fileProgress * Double(currentAssetBytes)) / totalBytes)
        )
    }

    private static func makeWarmUpBoard(in directory: URL) throws -> URL {
        let output = directory.appendingPathComponent("warmup-board.jpg")
        if FileManager.default.fileExists(atPath: output.path) { return output }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1024, height: 1024))
        let image = renderer.image { context in
            UIColor(white: 0.08, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
            UIColor.white.setFill()
            "Bricky on-device recovery warm-up".draw(
                in: CGRect(x: 80, y: 470, width: 864, height: 84),
                withAttributes: [.font: UIFont.systemFont(ofSize: 34, weight: .semibold), .foregroundColor: UIColor.white]
            )
        }
        guard let data = image.jpegData(compressionQuality: 0.9) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: output, options: .atomic)
        return output
    }
}

private final class NetworkPathProbe: @unchecked Sendable {
    static func current() async -> NWPath {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "com.bricky.recovery.network-probe")
            // `monitor.cancel()` is asynchronous, so the handler can fire
            // again before cancellation lands. The handler always runs on the
            // serial monitor queue, so this flag is race-free there; clear the
            // handler before resuming so the continuation resumes exactly once.
            var resumed = false
            monitor.pathUpdateHandler = { path in
                guard !resumed else { return }
                resumed = true
                monitor.pathUpdateHandler = nil
                monitor.cancel()
                continuation.resume(returning: path)
            }
            monitor.start(queue: queue)
        }
    }
}
