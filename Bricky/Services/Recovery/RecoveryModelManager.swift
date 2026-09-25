import ARKit
import Foundation
import Network
import OSLog
import RecoveryMLX
import UIKit

@MainActor
final class RecoveryModelManager: ObservableObject {
    nonisolated static let modelID = "mlx-community/Qwen3-VL-4B-Instruct-4bit"
    nonisolated static let revision = "2fd8dacbdb8f1e54b8c005f081ec5bf79c56376b"
    // 🟡 RECONSTRUCTED: physical-device profiling must replace this conservative
    // release floor with measured worst-case peak + 25% before App Store release.
    nonisolated static let minimumAvailableMemory: UInt64 = 5_500_000_000

    struct Asset: Sendable, Hashable {
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
    @Published var allowsCellularDownloads: Bool {
        didSet { defaults.set(allowsCellularDownloads, forKey: AppConfig.Defaults.allowsCellularModelDownload) }
    }
    /// Bytes the last prune reclaimed from superseded revisions.
    @Published private(set) var lastPrunedBytes: Int64 = 0
    /// What admission measured for the loaded model; evidence sessions carry
    /// it so the ADR 0003 floor can be set from device rows.
    @Published private(set) var admissionSnapshot: AdmissionSnapshot?
    /// What the last critical-pressure unload freed.
    @Published private(set) var lastPressureRelief: PressureRelief?

    let runtime = MLXRecoveryRuntime()
    private let downloader = VerifiedAssetDownloader()
    private let delivery: any ModelDelivery
    private let defaults: UserDefaults
    private let storageRoot: URL?
    private let deviceFloor: @MainActor () -> DeviceFloor.Verdict
    private let governor: MemoryGovernor
    private let memoryBudget: @MainActor () -> MemoryBudget
    private let pressure: any MemoryPressureSignaling
    private let idleUnloadInterval: Duration
    private let logger = Logger(subsystem: AppConfig.bundleID, category: "RecoveryModel")

    static let defaultIdleUnloadInterval: Duration = .seconds(300)

    /// Everything past `delivery` exists for tests; the app uses the
    /// Application Support root, the real device gate, the kernel's memory
    /// accounting, and the system's pressure notifications.
    init(
        delivery: any ModelDelivery = ForegroundVerifiedDelivery(),
        defaults: UserDefaults = .standard,
        storageRoot: URL? = nil,
        deviceFloor: @escaping @MainActor () -> DeviceFloor.Verdict = { DeviceFloor.current },
        governor: MemoryGovernor = .standard,
        memoryBudget: @escaping @MainActor () -> MemoryBudget = { MemoryBudget.current() },
        pressure: (any MemoryPressureSignaling)? = nil,
        idleUnloadInterval: Duration = RecoveryModelManager.defaultIdleUnloadInterval
    ) {
        self.delivery = delivery
        self.defaults = defaults
        self.storageRoot = storageRoot
        self.deviceFloor = deviceFloor
        self.governor = governor
        self.memoryBudget = memoryBudget
        self.pressure = pressure ?? DispatchMemoryPressureSignal()
        self.idleUnloadInterval = idleUnloadInterval
        allowsCellularDownloads = defaults.bool(forKey: AppConfig.Defaults.allowsCellularModelDownload)
        self.pressure.start { [weak self] level in self?.handleMemoryPressure(level) }
    }
    private enum WorkKind { case download, warmUp }
    private var workTask: Task<Void, Never>?
    private var workKind: WorkKind?
    private var trackedInference: [UUID: Task<Void, Never>] = [:]
    /// What the loaded model holds: the footprint after warm-up less the
    /// footprint before load. Zero while unloaded.
    private var modelResidentBytes: UInt64 = 0
    private var pressureTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?

    static let modelFolderName = "Qwen3-VL-4B-Instruct-4bit"

    private var recoveryModelsDirectory: URL? {
        guard let root = storageRoot ?? (try? InstructionModelImporter.applicationSupportRoot()) else { return nil }
        return try? StorageLayout.directory(.recoveryModels, root: root)
    }

    var modelDirectory: URL? {
        recoveryModelsDirectory?.appendingPathComponent("\(Self.modelFolderName)/\(Self.revision)", isDirectory: true)
    }

    var manifest: ModelManifest? {
        modelDirectory.map { ModelManifest(modelID: Self.modelID, revision: Self.revision, assets: Self.assets, directory: $0) }
    }

    var isVLMAdmitted: Bool {
        if case .admitted = state { return true }
        return false
    }

    /// The hierarchical VLM estimator, or nil unless the model is admitted:
    /// geometric recovery runs either way (ADR 0010 amendment).
    func makeVLMEstimator(
        partPackRoot: URL,
        recorder: RecoveryEvidenceRecorder?,
        variant: RecoveryInferenceVariant = .baseline
    ) -> HierarchicalRecoveryEstimator? {
        guard isVLMAdmitted, let modelDirectory else { return nil }
        return HierarchicalRecoveryEstimator(
            runtime: runtime,
            modelDirectory: modelDirectory,
            partPackRoot: partPackRoot,
            recorder: recorder,
            variant: variant
        )
    }

    /// Bytes the pinned revision occupies on disk, partial downloads included.
    var onDiskBytes: Int64 {
        guard let directory = modelDirectory,
              let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in files {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    /// Deletes every model revision except the pinned one — superseded pins
    /// would otherwise sit on disk forever at ~3 GB each.
    func pruneStaleRevisions() {
        guard let models = recoveryModelsDirectory else { return }
        let fileManager = FileManager.default
        var reclaimed: Int64 = 0
        func remove(_ url: URL) {
            if let files = fileManager.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) {
                for case let file as URL in files {
                    reclaimed += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
                }
            }
            try? fileManager.removeItem(at: url)
        }
        for model in (try? fileManager.contentsOfDirectory(at: models, includingPropertiesForKeys: nil)) ?? [] {
            guard model.lastPathComponent == Self.modelFolderName else {
                remove(model)
                continue
            }
            for revision in (try? fileManager.contentsOfDirectory(at: model, includingPropertiesForKeys: nil)) ?? []
            where revision.lastPathComponent != Self.revision {
                remove(revision)
            }
        }
        lastPrunedBytes = reclaimed
    }

    /// Unloads, deletes the pinned revision, and re-checks, which lands on
    /// "needs download". Guides and geometric features are unaffected.
    func removeModel() async throws {
        guard let manifest else { return }
        await cancelAndAwait()
        try await delivery.remove(manifest)
        admissionSnapshot = nil
        await check()
    }

    func check() async {
        let wasAdmitted = isVLMAdmitted
        state = .checking
        pruneStaleRevisions()
        guard deviceFloor() == .supported else {
            reject(reason: "Recovery needs iPhone 17 Pro or iPhone 17 Pro Max. Guides remain available.", retryable: false)
            return
        }
        guard governor.evaluate(memoryBudget(), modelResidentBytes: modelResidentBytes, currentlyAdmitted: wasAdmitted) == .admit else {
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
        idleTask?.cancel()
        Task { [weak self] in
            await task.value
            guard let self else { return }
            self.trackedInference[id] = nil
            if self.trackedInference.isEmpty { self.scheduleIdleUnload() }
        }
    }

    func cancelAndAwait() async {
        workTask?.cancel()
        await workTask?.value
        workTask = nil
        workKind = nil
        await drainTrackedInference()
        await unloadRuntime()
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
        await unloadRuntime()
    }

    private func unloadRuntime() async {
        idleTask?.cancel()
        await runtime.unload()
        modelResidentBytes = 0
        if case .admitted = state { state = .warming }
    }

    /// Critical memory pressure cancels inference and releases the model
    /// before iOS terminates the process for it (ADR 0003 amendment); a
    /// warning does the same only if the loaded model's headroom has fallen
    /// below the floor less the hysteresis margin. The budget is re-read
    /// 500 ms after the release, once the kernel has reclaimed the pages;
    /// if even the released model would not fit, admission is withdrawn
    /// until the user retries. Downloads are left running: they hold no
    /// model memory.
    func handleMemoryPressure(_ level: MemoryPressureLevel) {
        logger.notice("Memory pressure \(level == .critical ? "critical" : "warning", privacy: .public)")
        guard pressureTask == nil else { return }
        if level == .warning {
            guard isVLMAdmitted,
                  case .refuse = governor.evaluate(memoryBudget(), modelResidentBytes: modelResidentBytes, currentlyAdmitted: true)
            else { return }
        }
        pressureTask = Task { [weak self] in
            await self?.relieveMemoryPressure()
            self?.pressureTask = nil
        }
    }

    private func relieveMemoryPressure() async {
        let wasLive = isVLMAdmitted || state == .warming
        let before = memoryBudget()
        await suspendInferenceAndAwait()
        try? await Task.sleep(for: .milliseconds(500))
        let after = memoryBudget()
        let relief = PressureRelief(before: before, after: after)
        lastPressureRelief = relief
        logger.notice("Pressure unload freed \(relief.freedBytes, privacy: .public) bytes")
        if wasLive, case .refuse = governor.evaluate(after, modelResidentBytes: 0, currentlyAdmitted: false) {
            reject(reason: "iOS is short of memory, so on-device recovery was paused. Close other apps and retry, or continue with guides.", retryable: true)
        }
    }

    /// Developer setting, off by default: release an idle model after
    /// `idleUnloadInterval`, trading a reload for memory.
    private func scheduleIdleUnload() {
        idleTask?.cancel()
        guard defaults.bool(forKey: AppConfig.Defaults.idleUnloadEnabled), isVLMAdmitted else { return }
        let interval = idleUnloadInterval
        idleTask = Task { [weak self] in
            do { try await Task.sleep(for: interval) } catch { return }
            guard let self, self.trackedInference.isEmpty, self.isVLMAdmitted else { return }
            self.logger.notice("Idle unload of the recovery model")
            await self.suspendInferenceAndAwait()
        }
    }

    private func performDownload() async {
        do {
            let path = await NetworkPathProbe.current()
            if path.usesInterfaceType(.cellular), !allowsCellularDownloads {
                reject(reason: "The recovery model is about 3.1 GB. Connect to Wi‑Fi or allow cellular download, then retry.", retryable: true)
                return
            }
            guard let manifest else { throw CocoaError(.fileNoSuchFile) }
            try await delivery.deliver(manifest) { progress in
                await self.updateDownloadProgress(progress)
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
            let budget = memoryBudget()
            guard governor.evaluate(budget, modelResidentBytes: modelResidentBytes, currentlyAdmitted: false) == .admit else {
                throw RecoveryError.insufficientMemory(
                    requiredBytes: Int64(governor.floorBytes),
                    availableBytes: Int64(governor.headroom(budget, modelResidentBytes: modelResidentBytes))
                )
            }
            guard let directory = modelDirectory else { throw CocoaError(.fileNoSuchFile) }
            let board = try Self.makeWarmUpBoard(in: directory)
            let footprintBeforeLoad = ProcessMemorySnapshot.current()?.footprintBytes
            var snapshot = AdmissionSnapshot(
                floorBytes: Int64(governor.floorBytes),
                availableBytesAtCheck: Int64(budget.availableBytes),
                footprintBeforeLoadBytes: footprintBeforeLoad
            )
            let loadStarted = ContinuousClock.now
            try await runtime.load(modelDirectory: directory)
            snapshot.loadMilliseconds = Self.milliseconds(since: loadStarted)
            // ✅ VERIFIED: the first production-shaped inference, not weight
            // loading, is the admission fit test.
            let warmUpStarted = ContinuousClock.now
            try await runtime.warmUp(imageURL: board, modelDirectory: directory)
            snapshot.warmUpMilliseconds = Self.milliseconds(since: warmUpStarted)
            let afterWarmUp = ProcessMemorySnapshot.current()
            snapshot.warmUpPeakBytes = afterWarmUp?.lifetimePeakBytes
            if let before = footprintBeforeLoad, let after = afterWarmUp?.footprintBytes, after > before {
                modelResidentBytes = UInt64(after - before)
            }
            admissionSnapshot = snapshot
            state = .admitted
            scheduleIdleUnload()
        } catch is CancellationError {
            state = .warming
        } catch {
            await runtime.unload()
            reject(reason: "Recovery warm-up failed: \(error.localizedDescription)", retryable: true)
        }
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let components = start.duration(to: .now).components
        return Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
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

    private func updateDownloadProgress(_ progress: Double) {
        state = .downloading(progress: progress)
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
