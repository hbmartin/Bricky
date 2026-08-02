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

        let available = try destinationURL.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage ?? 0
        let existingPartial = (try? partialURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let required = max(0, expectedBytes - existingPartial)
        guard available >= required else {
            throw VerifiedAssetError.insufficientStorage(required: required, available: available)
        }

        let partialBytes = (try? partialURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        var request = URLRequest(url: remoteURL)
        if partialBytes > 0 {
            request.setValue("bytes=\(partialBytes)-", forHTTPHeaderField: "Range")
        }

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 || http.statusCode == 206 else {
            throw VerifiedAssetError.unexpectedResponse
        }
        let shouldAppend = partialBytes > 0 && http.statusCode == 206
        if shouldAppend {
            let contentRange = http.value(forHTTPHeaderField: "Content-Range") ?? ""
            guard contentRange.lowercased().hasPrefix("bytes \(partialBytes)-") else {
                throw VerifiedAssetError.unexpectedResponse
            }
        }
        if !shouldAppend {
            try? fileManager.removeItem(at: partialURL)
            fileManager.createFile(atPath: partialURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: partialURL)
        if shouldAppend { try handle.seekToEnd() }
        defer { try? handle.close() }

        var received = shouldAppend ? partialBytes : 0
        var buffer = Data()
        buffer.reserveCapacity(512 * 1024)
        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)
            if buffer.count >= 512 * 1024 {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                await progress?(min(1, Double(received) / Double(expectedBytes)))
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
        }
        try handle.synchronize()
        guard received == expectedBytes else {
            if received > expectedBytes { try? fileManager.removeItem(at: partialURL) }
            throw VerifiedAssetError.sizeMismatch(expected: expectedBytes, actual: received)
        }
        guard try verify(partialURL, expectedBytes: expectedBytes, expectedSHA256: expectedSHA256) else {
            try? fileManager.removeItem(at: partialURL)
            throw VerifiedAssetError.hashMismatch
        }
        try? fileManager.removeItem(at: destinationURL)
        try fileManager.moveItem(at: partialURL, to: destinationURL)
        await progress?(1)
    }

    func verify(_ url: URL, expectedBytes: Int64, expectedSHA256: String) throws -> Bool {
        let actualBytes = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? -1
        guard actualBytes == expectedBytes else { return false }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return digest.caseInsensitiveCompare(expectedSHA256) == .orderedSame
    }
}
