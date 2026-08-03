import CryptoKit
import Foundation

enum VerifiedAssetError: LocalizedError {
    case unexpectedResponse
    case sizeMismatch(expected: Int64, actual: Int64)
    case hashMismatch
    case insufficientStorage(required: Int64, available: Int64)

    var errorDescription: String? {
        switch self {
        case .unexpectedResponse:
            return "The asset server returned an unexpected response."
        case let .sizeMismatch(expected, actual):
            return "The download is incomplete (expected \(expected) bytes, received \(actual))."
        case .hashMismatch:
            return "The downloaded asset failed its SHA-256 integrity check."
        case let .insufficientStorage(required, available):
            return "The asset needs \(ByteCountFormatter.string(fromByteCount: required, countStyle: .file)); \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) is available."
        }
    }
}

actor VerifiedAssetDownloader {
    typealias Progress = @Sendable (Double) async -> Void

    func download(
        from remoteURL: URL,
        to destinationURL: URL,
        expectedBytes: Int64,
        expectedSHA256: String,
        progress: Progress? = nil
    ) async throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partialURL = destinationURL.appendingPathExtension("partial")
        if fileManager.fileExists(atPath: destinationURL.path),
           try verify(destinationURL, expectedBytes: expectedBytes, expectedSHA256: expectedSHA256) {
            await progress?(1)
            return
        }
        try? fileManager.removeItem(at: destinationURL)
        try? fileManager.removeItem(at: Self.markerURL(for: destinationURL))

        let available = try destinationURL.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage ?? 0
        let partialBytes = (try? partialURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let required = max(0, expectedBytes - partialBytes)
        guard available >= required else {
            throw VerifiedAssetError.insufficientStorage(required: required, available: available)
        }

        var request = URLRequest(url: remoteURL)
        if partialBytes > 0 {
            request.setValue("bytes=\(partialBytes)-", forHTTPHeaderField: "Range")
        }

        var progressTask: Task<Void, Never>?
        var progressContinuation: AsyncStream<Double>.Continuation?
        if let progress {
            let (stream, continuation) = AsyncStream<Double>.makeStream()
            progressContinuation = continuation
            progressTask = Task {
                for await value in stream {
                    await progress(value)
                }
            }
        }
        defer { progressContinuation?.finish() }

        // A delegate-based data task streams chunks straight to disk. The old
        // per-byte AsyncBytes loop was CPU-bound for multi-gigabyte assets.
        let transfer = ChunkedDownloadTransfer(
            partialURL: partialURL,
            expectedBytes: expectedBytes,
            requestedOffset: partialBytes,
            progress: progressContinuation
        )
        let session = URLSession(configuration: .ephemeral, delegate: transfer, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let received: Int64
        do {
            received = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int64, Error>) in
                    transfer.begin(request: request, session: session, continuation: continuation)
                }
            } onCancel: {
                transfer.cancel()
            }
        } catch {
            // A wedged partial must never survive a non-resumable response or
            // an over-long stream: the next attempt has to restart cleanly.
            switch error {
            case VerifiedAssetError.unexpectedResponse:
                try? fileManager.removeItem(at: partialURL)
                try? fileManager.removeItem(at: Self.markerURL(for: partialURL))
            case let VerifiedAssetError.sizeMismatch(expected, actual) where actual > expected:
                try? fileManager.removeItem(at: partialURL)
                try? fileManager.removeItem(at: Self.markerURL(for: partialURL))
            default:
                break
            }
            throw error
        }

        progressContinuation?.finish()
        await progressTask?.value

        guard received == expectedBytes else {
            throw VerifiedAssetError.sizeMismatch(expected: expectedBytes, actual: received)
        }
        guard try verify(partialURL, expectedBytes: expectedBytes, expectedSHA256: expectedSHA256, force: true) else {
            try? fileManager.removeItem(at: partialURL)
            try? fileManager.removeItem(at: Self.markerURL(for: partialURL))
            throw VerifiedAssetError.hashMismatch
        }
        try? fileManager.removeItem(at: destinationURL)
        try fileManager.moveItem(at: partialURL, to: destinationURL)
        // The rename preserves size and modification time, so the marker that
        // `verify` wrote for the partial stays valid for the destination.
        try? fileManager.removeItem(at: Self.markerURL(for: destinationURL))
        try? fileManager.moveItem(at: Self.markerURL(for: partialURL), to: Self.markerURL(for: destinationURL))
        await progress?(1)
    }

    /// Verifies size and SHA-256. A successful full verification writes a
    /// sidecar marker so later launches can skip re-hashing unchanged assets;
    /// `force` bypasses the marker and always hashes.
    func verify(_ url: URL, expectedBytes: Int64, expectedSHA256: String, force: Bool = false) throws -> Bool {
        // FileManager reads attributes fresh every call; URL.resourceValues
        // can serve stale cached values on a URL instance that was already
        // queried earlier in the same download.
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let actualBytes = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard actualBytes == expectedBytes else { return false }
        let modified = attributes[.modificationDate] as? Date
        if !force, Self.markerMatches(url: url, expectedSHA256: expectedSHA256, bytes: actualBytes, modified: modified) {
            return true
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest.caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
            try? FileManager.default.removeItem(at: Self.markerURL(for: url))
            return false
        }
        Self.writeMarker(for: url, sha256: digest, bytes: actualBytes, modified: modified)
        return true
    }

    private static func markerURL(for url: URL) -> URL {
        url.appendingPathExtension("verified")
    }

    private static func markerMatches(url: URL, expectedSHA256: String, bytes: Int64, modified: Date?) -> Bool {
        guard let modified,
              let text = try? String(contentsOf: markerURL(for: url), encoding: .utf8) else { return false }
        let fields = text.split(separator: "\n").map(String.init)
        guard fields.count == 3,
              fields[0].caseInsensitiveCompare(expectedSHA256) == .orderedSame,
              Int64(fields[1]) == bytes,
              let storedInterval = Double(fields[2]) else { return false }
        return abs(storedInterval - modified.timeIntervalSince1970) < 0.000_5
    }

    private static func writeMarker(for url: URL, sha256: String, bytes: Int64, modified: Date?) {
        guard let modified else { return }
        let contents = "\(sha256)\n\(bytes)\n\(modified.timeIntervalSince1970)\n"
        try? Data(contents.utf8).write(to: markerURL(for: url), options: .atomic)
    }
}

/// Streams one HTTP transfer to the partial file: validates the response,
/// appends chunks, enforces the pinned byte size per chunk, throttles
/// progress, and resumes the awaiting continuation exactly once on completion.
private final class ChunkedDownloadTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let partialURL: URL
    private let expectedBytes: Int64
    private let requestedOffset: Int64
    private let progress: AsyncStream<Double>.Continuation?

    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<Int64, Error>?
    private var cancelled = false

    // Written only on the session's serial delegate queue.
    private var handle: FileHandle?
    private var baseOffset: Int64 = 0
    private var received: Int64 = 0
    private var lastReportedBytes: Int64 = 0
    private var failure: Error?

    init(
        partialURL: URL,
        expectedBytes: Int64,
        requestedOffset: Int64,
        progress: AsyncStream<Double>.Continuation?
    ) {
        self.partialURL = partialURL
        self.expectedBytes = expectedBytes
        self.requestedOffset = requestedOffset
        self.progress = progress
    }

    func begin(request: URLRequest, session: URLSession, continuation: CheckedContinuation<Int64, Error>) {
        lock.lock()
        self.continuation = continuation
        let task = session.dataTask(with: request)
        self.task = task
        let alreadyCancelled = cancelled
        lock.unlock()
        if alreadyCancelled { task.cancel() }
        task.resume()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 || http.statusCode == 206 else {
            failure = VerifiedAssetError.unexpectedResponse
            completionHandler(.cancel)
            return
        }
        let appends = requestedOffset > 0 && http.statusCode == 206
        if appends {
            let contentRange = http.value(forHTTPHeaderField: "Content-Range") ?? ""
            guard contentRange.lowercased().hasPrefix("bytes \(requestedOffset)-") else {
                failure = VerifiedAssetError.unexpectedResponse
                completionHandler(.cancel)
                return
            }
        }
        do {
            if !appends {
                try? FileManager.default.removeItem(at: partialURL)
                FileManager.default.createFile(atPath: partialURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: partialURL)
            if appends { try handle.seekToEnd() }
            self.handle = handle
            baseOffset = appends ? requestedOffset : 0
            lastReportedBytes = baseOffset
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil, let handle else { return }
        let projected = baseOffset + received + Int64(data.count)
        guard projected <= expectedBytes else {
            // A lying server must not fill the disk: abort the moment the
            // stream exceeds the pinned size.
            failure = VerifiedAssetError.sizeMismatch(expected: expectedBytes, actual: projected)
            dataTask.cancel()
            return
        }
        do {
            try handle.write(contentsOf: data)
            received += Int64(data.count)
            let absolute = baseOffset + received
            if absolute - lastReportedBytes >= 512 * 1024 || absolute == expectedBytes {
                lastReportedBytes = absolute
                progress?.yield(min(1, Double(absolute) / Double(expectedBytes)))
            }
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        if let failure {
            continuation?.resume(throwing: failure)
        } else if let error {
            if (error as? URLError)?.code == .cancelled {
                continuation?.resume(throwing: CancellationError())
            } else {
                continuation?.resume(throwing: error)
            }
        } else {
            continuation?.resume(returning: baseOffset + received)
        }
    }
}
