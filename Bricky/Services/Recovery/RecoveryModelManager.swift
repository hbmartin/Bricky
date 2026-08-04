import ARKit
import Foundation
import Network
import RecoveryMLX
import UIKit

@MainActor
final class RecoveryModelManager: ObservableObject {
    nonisolated static let modelID = "mlx-community/Qwen2.5-VL-3B-Instruct-4bit"
    nonisolated static let revision = "46d4cf06a06ffc1a766c214174f9cbed2f45bcab"
    // 🟡 RECONSTRUCTED: physical-device profiling must replace this conservative
    // release floor with measured worst-case peak + 25% before App Store release.
    nonisolated static let minimumAvailableMemory: UInt64 = 5_500_000_000

    struct Asset: Sendable {
        let path: String
        let bytes: Int64
        let sha256: String
    }

    static let assets: [Asset] = [
        .init(path: "added_tokens.json", bytes: 605, sha256: "58b54bbe36fc752f79a24a271ef66a0a0830054b4dfad94bde757d851968060b"),
        .init(path: "chat_template.json", bytes: 1_050, sha256: "ad60d90252ed0b0705ba14e2d0ad0fec0beac1ea955642b54059b36052d8bc96"),
        .init(path: "config.json", bytes: 1_659, sha256: "7ed631bd2786d251cb38bd2a6a8a78c31bc1316f728bffa84b2d8954d3cfcd63"),
        .init(path: "merges.txt", bytes: 1_671_853, sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
        .init(path: "model.safetensors", bytes: 3_073_720_461, sha256: "636982419c940321ac0f7793dc9dc3575a4ee4843a6b167b2e8c3d3cd25dacf4"),
        .init(path: "model.safetensors.index.json", bytes: 108_307, sha256: "3dacd0399838beaa368c4a4278477096c861defca3cfdcdd6f947b62d349af32"),
        .init(path: "preprocessor_config.json", bytes: 350, sha256: "f2058c716eef96ccaed1cc1e2d0c08306b62586d535b28d9d08e691b2fab7ca0"),
        .init(path: "special_tokens_map.json", bytes: 613, sha256: "76862e765266b85aa9459767e33cbaf13970f327a0e88d1c65846c2ddd3a1ecd"),
        .init(path: "tokenizer.json", bytes: 11_421_896, sha256: "9c5ae00e602b8860cbd784ba82a8aa14e8feecec692e7076590d014d7b7fdafa"),
        .init(path: "tokenizer_config.json", bytes: 7_256, sha256: "2f58f4bbd7bbce15d683f525954ef3a92cd82f5e06415a9c513859bf8ab72436"),
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
            .appendingPathComponent("RecoveryModels/Qwen2.5-VL-3B-Instruct-4bit/\(Self.revision)", isDirectory: true)
    }

    func check() async {
        state = .checking
        guard ARWorldTrackingConfiguration.isSupported else {
            reject(reason: "Recovery needs ARKit world tracking. Guides remain available.", retryable: false)
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
                reject(reason: "The recovery model is about 3.09 GB. Connect to Wi‑Fi or allow cellular download, then retry.", retryable: true)
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
