import Foundation
import OSLog

/// What the background delivery needs from a transfer engine; the app's
/// background `URLSession` in production, a fake in tests.
protocol BackgroundTransferring: Sendable {
    /// Descriptions of every transfer still running or waiting, including
    /// ones a previous launch started.
    func activeDescriptions() async -> Set<String>
    func start(_ request: URLRequest, description: String, expectedBytes: Int64)
    func resume(from resumeData: Data, description: String, expectedBytes: Int64)
    /// The error that ended the transfer, once; nil if it succeeded, was
    /// never started in this launch, or left resume data behind.
    func takeFailure(_ description: String) -> Error?
    /// Bytes written so far by the running transfer, for progress.
    func bytesWritten(_ description: String) -> Int64
    func cancel(_ descriptions: Set<String>) async
}

/// Model delivery that survives backgrounding and termination (ADR 0003
/// amendment; ROADMAP §C). A background `URLSession` owns the transfers, so
/// a 3 GB download keeps going when the user leaves the app.
///
/// Verification stays in the foreground. The session's delegate only moves
/// a finished file beside its destination as `<asset>.downloaded` — hashing
/// 3 GB would outlast any background launch — and `reconcile` hashes and
/// publishes it the next time the app runs. Nothing is published unverified,
/// exactly as with the foreground downloader.
///
/// Transfers start only from `deliver`, which the manager calls from the
/// foreground download button; a relaunch only re-attaches to transfers
/// already running.
struct BackgroundURLSessionDelivery: ModelDelivery {
    let transfer: any BackgroundTransferring
    let verifier: VerifiedAssetDownloader
    let pollInterval: Duration
    /// Failed, unverifiable, or refused rounds per asset before giving up.
    /// A pause that left resume data is not a failed round; pauses that
    /// wrote nothing have their own budget of the same size.
    let maximumAttempts: Int

    init(
        transfer: any BackgroundTransferring = BackgroundModelTransfer.shared,
        verifier: VerifiedAssetDownloader = VerifiedAssetDownloader(),
        pollInterval: Duration = .seconds(1),
        maximumAttempts: Int = 3
    ) {
        self.transfer = transfer
        self.verifier = verifier
        self.pollInterval = pollInterval
        self.maximumAttempts = maximumAttempts
    }

    static func description(of asset: RecoveryModelManager.Asset, in manifest: ModelManifest) -> String {
        "\(manifest.revision)/\(asset.path)"
    }

    static func downloadedURL(for destination: URL) -> URL {
        destination.appendingPathExtension("downloaded")
    }

    static func resumeDataURL(for destination: URL) -> URL {
        destination.appendingPathExtension("resume")
    }

    func deliver(
        _ manifest: ModelManifest,
        allowsCellular: Bool,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws {
        try FileManager.default.createDirectory(at: manifest.directory, withIntermediateDirectories: true)
        var attempts: [String: Int] = [:]
        var stalls: [String: Int] = [:]
        var lastCause: [String: Error] = [:]
        while true {
            try Task.checkCancellation()
            // Look before publishing: a transfer moves its file into place
            // before it leaves the active set, so one that finishes while
            // `publish` hashes is published next round, never started again.
            let active = await transfer.activeDescriptions()
            let (missing, rejected) = await publish(manifest)
            if missing.isEmpty {
                await progress(1)
                return
            }
            for asset in missing {
                let description = Self.description(of: asset, in: manifest)
                guard !active.contains(description) else { continue }
                let destination = manifest.directory.appendingPathComponent(asset.path)
                let resumeURL = Self.resumeDataURL(for: destination)
                let failure = transfer.takeFailure(description)
                // Resume data from a failed attempt may carry an expired
                // signed CDN URL; after a failure, start over.
                let resumeData = failure == nil ? try? Data(contentsOf: resumeURL) : nil
                try? FileManager.default.removeItem(at: resumeURL)
                if let resumeData {
                    // A pause is not a failed round, but a transfer that
                    // keeps pausing without writing a byte is stuck.
                    if transfer.bytesWritten(description) > 0 {
                        stalls[description] = 0
                    } else {
                        let stalled = (stalls[description] ?? 0) + 1
                        stalls[description] = stalled
                        guard stalled <= maximumAttempts else {
                            throw ModelTransferError.stalled(asset: asset.path)
                        }
                    }
                    transfer.resume(from: resumeData, description: description, expectedBytes: asset.bytes)
                    continue
                }
                if let cause = failure ?? (rejected.contains(asset.path) ? VerifiedAssetError.hashMismatch : nil) {
                    lastCause[description] = cause
                }
                let attempt = (attempts[description] ?? 0) + 1
                attempts[description] = attempt
                guard attempt <= maximumAttempts else {
                    throw lastCause[description] ?? ModelTransferError.interrupted(asset: asset.path)
                }
                // Leftovers of the foreground downloader are not resumable
                // here and must not be credited as progress.
                try? FileManager.default.removeItem(at: destination.appendingPathExtension("partial"))
                var request = URLRequest(url: manifest.remoteURL(for: asset))
                request.allowsCellularAccess = allowsCellular
                transfer.start(request, description: description, expectedBytes: asset.bytes)
            }
            // Cancellation ends this wait, never the transfers: the manager
            // re-attaches when the app returns.
            let waiting = Set(missing.map { Self.description(of: $0, in: manifest) })
            while true {
                try await Task.sleep(for: pollInterval)
                let stillActive = await transfer.activeDescriptions().intersection(waiting)
                await progress(fractionComplete(manifest))
                if stillActive.isEmpty { break }
            }
        }
    }

    /// Publishes what finished while the app was away, and reports whether
    /// transfers a previous launch started are still running.
    func reconcile(_ manifest: ModelManifest) async -> DeliveryStatus {
        let missing = await publishDownloaded(manifest)
        guard !missing.isEmpty else { return .idle }
        let descriptions = Set(missing.map { Self.description(of: $0, in: manifest) })
        return descriptions.isDisjoint(with: await transfer.activeDescriptions()) ? .idle : .transferring
    }

    /// Hashes and publishes every `.downloaded` file for `manifest`, deletes
    /// any that fail, and returns the assets still not on disk. Foreground
    /// only: this is the only place a background download is verified.
    func publishDownloaded(_ manifest: ModelManifest) async -> [RecoveryModelManager.Asset] {
        await publish(manifest).missing
    }

    /// `publishDownloaded`, also naming the assets whose downloaded file
    /// failed verification and was deleted.
    private func publish(_ manifest: ModelManifest) async -> (missing: [RecoveryModelManager.Asset], rejected: Set<String>) {
        let fileManager = FileManager.default
        var missing: [RecoveryModelManager.Asset] = []
        var rejected: Set<String> = []
        for asset in manifest.assets {
            let destination = manifest.directory.appendingPathComponent(asset.path)
            let downloaded = Self.downloadedURL(for: destination)
            if fileManager.fileExists(atPath: downloaded.path) {
                if (try? await verifier.verify(downloaded, expectedBytes: asset.bytes, expectedSHA256: asset.sha256, force: true)) == true {
                    try? fileManager.removeItem(at: destination)
                    try? fileManager.removeItem(at: destination.appendingPathExtension("verified"))
                    do {
                        try fileManager.moveItem(at: downloaded, to: destination)
                        // The rename keeps size and modification time, so the
                        // marker written for the downloaded file stays valid.
                        try? fileManager.moveItem(
                            at: downloaded.appendingPathExtension("verified"),
                            to: destination.appendingPathExtension("verified")
                        )
                    } catch {
                        missing.append(asset)
                        continue
                    }
                } else {
                    try? fileManager.removeItem(at: downloaded)
                    try? fileManager.removeItem(at: downloaded.appendingPathExtension("verified"))
                    rejected.insert(asset.path)
                }
            }
            var published = false
            if fileManager.fileExists(atPath: destination.path) {
                published = (try? await verifier.verify(destination, expectedBytes: asset.bytes, expectedSHA256: asset.sha256)) == true
            }
            if !published { missing.append(asset) }
        }
        return (missing, rejected)
    }

    func remove(_ manifest: ModelManifest) async throws {
        await transfer.cancel(Set(manifest.assets.map { Self.description(of: $0, in: manifest) }))
        guard FileManager.default.fileExists(atPath: manifest.directory.path) else { return }
        try FileManager.default.removeItem(at: manifest.directory)
    }

    private func fractionComplete(_ manifest: ModelManifest) -> Double {
        let fileManager = FileManager.default
        var done: Int64 = 0
        for asset in manifest.assets {
            let destination = manifest.directory.appendingPathComponent(asset.path)
            if fileManager.fileExists(atPath: destination.path)
                || fileManager.fileExists(atPath: Self.downloadedURL(for: destination).path) {
                done += asset.bytes
            } else {
                done += min(asset.bytes, transfer.bytesWritten(Self.description(of: asset, in: manifest)))
            }
        }
        return min(1, Double(done) / Double(max(1, manifest.totalBytes)))
    }
}

/// Why background delivery gave up when no transfer failed outright.
enum ModelTransferError: LocalizedError, Equatable {
    /// The transfer kept pausing without writing anything.
    case stalled(asset: String)
    /// The transfer kept ending without a file, an error, or resume data.
    case interrupted(asset: String)

    var errorDescription: String? {
        switch self {
        case .stalled(let asset):
            return "The download of \(asset) stopped making progress. Check your connection and try again."
        case .interrupted(let asset):
            return "The download of \(asset) kept being interrupted. Try again."
        }
    }
}

/// The app's one background `URLSession` for model downloads.
///
/// Its delegate may run in a launch the system made only to deliver session
/// events, before any view or manager exists, so everything it needs is
/// derived from the task itself: the description names the revision and
/// asset, and `destination` maps that to a file.
final class BackgroundModelTransfer: NSObject, BackgroundTransferring, URLSessionDownloadDelegate, @unchecked Sendable {
    static let identifier = "\(AppConfig.bundleID).model-download"
    static let shared = BackgroundModelTransfer(identifier: identifier) { description in
        // Only the pinned revision has a destination: transfers a previous
        // app version started for an older pin are dropped on arrival.
        let parts = description.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0] == RecoveryModelManager.revision,
              let root = try? InstructionModelImporter.applicationSupportRoot(),
              let models = try? StorageLayout.directory(.recoveryModels, root: root) else { return nil }
        return models
            .appendingPathComponent("\(RecoveryModelManager.modelFolderName)/\(parts[0])", isDirectory: true)
            .appendingPathComponent(parts[1])
    }

    private let identifier: String
    private let destination: @Sendable (String) -> URL?
    private let logger = Logger(subsystem: AppConfig.bundleID, category: "ModelDownload")
    private let lock = NSLock()
    private var session: URLSession?
    private var failures: [String: Error] = [:]
    private var written: [String: Int64] = [:]
    private var expected: [String: Int64] = [:]
    private var eventsFinished: [CheckedContinuation<Void, Never>] = []
    /// Set when iOS finished delivering events before a handler waited.
    private var eventsDelivered = false

    init(identifier: String, destination: @escaping @Sendable (String) -> URL?) {
        self.identifier = identifier
        self.destination = destination
    }

    /// Created on first use, including in a launch made for session events.
    private var urlSession: URLSession {
        lock.lock()
        defer { lock.unlock() }
        if let session { return session }
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        // Started by the user from the foreground, so never deferred to
        // "a good time"; iOS still pauses it without connectivity.
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        return session
    }

    /// For `.backgroundTask(.urlSession(_:))`: reconnects to the session
    /// and returns once iOS has delivered every pending event.
    func handleBackgroundEvents() async {
        _ = urlSession
        await withCheckedContinuation { continuation in
            lock.lock()
            if eventsDelivered {
                eventsDelivered = false
                lock.unlock()
                continuation.resume()
                return
            }
            eventsFinished.append(continuation)
            lock.unlock()
        }
    }

    // MARK: BackgroundTransferring

    func activeDescriptions() async -> Set<String> {
        let tasks = await urlSession.allTasks
        return Set(tasks.compactMap { task in
            task.state == .running || task.state == .suspended ? task.taskDescription : nil
        })
    }

    func start(_ request: URLRequest, description: String, expectedBytes: Int64) {
        begin(urlSession.downloadTask(with: request), description: description, expectedBytes: expectedBytes)
    }

    func resume(from resumeData: Data, description: String, expectedBytes: Int64) {
        begin(urlSession.downloadTask(withResumeData: resumeData), description: description, expectedBytes: expectedBytes)
    }

    private func begin(_ task: URLSessionDownloadTask, description: String, expectedBytes: Int64) {
        task.taskDescription = description
        lock.lock()
        failures[description] = nil
        expected[description] = expectedBytes
        written[description] = 0
        lock.unlock()
        task.resume()
    }

    func takeFailure(_ description: String) -> Error? {
        lock.lock()
        defer { lock.unlock() }
        return failures.removeValue(forKey: description)
    }

    func bytesWritten(_ description: String) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return written[description] ?? 0
    }

    func cancel(_ descriptions: Set<String>) async {
        for task in await urlSession.allTasks where descriptions.contains(task.taskDescription ?? "") {
            task.cancel()
        }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let description = downloadTask.taskDescription else { return }
        lock.lock()
        written[description] = totalBytesWritten
        let limit = expected[description]
        lock.unlock()
        // A server streaming past the pinned size must not fill the disk.
        if let limit, totalBytesWritten > limit {
            record(VerifiedAssetError.sizeMismatch(expected: limit, actual: totalBytesWritten), for: description)
            downloadTask.cancel()
        }
    }

    /// Only moves the file: the temporary file is deleted when this returns,
    /// and hashing it here would outlast a background launch.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let description = downloadTask.taskDescription,
              let destination = destination(description) else { return }
        // 206 is a transfer resumed from resume data.
        guard let http = downloadTask.response as? HTTPURLResponse, http.statusCode == 200 || http.statusCode == 206 else {
            record(VerifiedAssetError.unexpectedResponse, for: description)
            return
        }
        let downloaded = BackgroundURLSessionDelivery.downloadedURL(for: destination)
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: downloaded)
            try FileManager.default.moveItem(at: location, to: downloaded)
        } catch {
            record(error, for: description)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let description = task.taskDescription, let error else { return }
        // Resume data is kept for the next start; only a transfer that left
        // none behind (or was refused outright) counts as failed.
        if let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
           let destination = destination(description) {
            try? resumeData.write(to: BackgroundURLSessionDelivery.resumeDataURL(for: destination), options: .atomic)
            logger.notice("Model transfer \(description, privacy: .public) paused with resume data")
            return
        }
        if (error as? URLError)?.code == .cancelled { return }
        record(error, for: description)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let waiting = eventsFinished
        eventsFinished.removeAll()
        eventsDelivered = waiting.isEmpty
        lock.unlock()
        for continuation in waiting { continuation.resume() }
    }

    private func record(_ error: Error, for description: String) {
        logger.error("Model transfer \(description, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        lock.lock()
        // The first cause wins: a cancel after a size overrun is not news.
        if failures[description] == nil { failures[description] = error }
        lock.unlock()
    }
}
