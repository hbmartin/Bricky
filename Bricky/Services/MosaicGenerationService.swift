import Foundation
import UIKit
import os.log

/// HTTP client for the LEGO Model Generation backend
/// (`services/lego-model-gen`, see `docs/LEGO Model Generation System/API_DESIGN.md`).
///
/// Provides the four primitive calls of the async job workflow plus an
/// artifact downloader. Polling is intentionally left to the caller
/// (`MosaicGeneratorViewModel`) so the UI can surface live progress.
///
/// The service is an `actor` for safe concurrent access and is injectable
/// (`baseURL`, `session`) so tests can drive it with a stubbed `URLProtocol`
/// — no live backend required.
actor MosaicGenerationService {

    static let shared = MosaicGenerationService()

    private nonisolated static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? AppConfig.bundleId,
        category: "MosaicGenerationService"
    )

    // MARK: - Errors

    enum ServiceError: LocalizedError, Equatable {
        case imageEncodingFailed
        case unreachable
        case server(status: Int, message: String?)
        case notReady(status: MosaicJobStatus)
        case decodingFailed
        case invalidArtifactURL

        var errorDescription: String? {
            switch self {
            case .imageEncodingFailed:
                return L10n.mosaicErrorImageEncoding
            case .unreachable:
                return L10n.mosaicErrorUnreachable
            case let .server(status, message):
                return message ?? L10n.mosaicErrorServer(status)
            case .notReady:
                return L10n.mosaicErrorNotReady
            case .decodingFailed:
                return L10n.mosaicErrorDecoding
            case .invalidArtifactURL:
                return L10n.mosaicErrorArtifactURL
            }
        }
    }

    // MARK: - Configuration

    private let baseURL: URL
    private let session: URLSession
    private let decoder = JSONDecoder()

    init(baseURL: URL = AppConfig.mosaicApiBaseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// The configured backend base URL (read-only, for diagnostics/UI).
    nonisolated var configuredBaseURL: URL { baseURL }

    // MARK: - Job Workflow

    /// `POST /jobs` — upload a photo and grid/palette config.
    ///
    /// The image is JPEG-encoded; oversized encodings are recompressed to stay
    /// under the backend's 20 MB cap before any upload begins.
    func submitJob(
        image: UIImage,
        width: Int,
        height: Int,
        palette: String = MosaicGenerator.defaultPaletteId,
        backgroundRemoval: Bool = false
    ) async throws -> MosaicJobCreation {
        guard let imageData = encodeJPEG(image) else {
            throw ServiceError.imageEncodingFailed
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        appendField(&body, boundary: boundary, name: "width", value: String(width))
        appendField(&body, boundary: boundary, name: "height", value: String(height))
        appendField(&body, boundary: boundary, name: "palette", value: palette)
        appendField(
            &body,
            boundary: boundary,
            name: "background_removal",
            value: backgroundRemoval ? "true" : "false"
        )
        appendFile(
            &body,
            boundary: boundary,
            name: "image",
            filename: "source.jpg",
            contentType: "image/jpeg",
            data: imageData
        )
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: endpoint("jobs"))
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = body

        let data = try await perform(request, accepting: 202)
        return try decode(MosaicJobCreation.self, from: data)
    }

    /// `GET /jobs/{id}` — poll status/progress.
    func jobStatus(id: String) async throws -> MosaicJobProgress {
        var request = URLRequest(url: endpoint("jobs/\(id)"))
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let data = try await perform(request, accepting: 200)
        return try decode(MosaicJobProgress.self, from: data)
    }

    /// `GET /jobs/{id}/result` — artifact URLs once the job is `done`.
    func jobResult(id: String) async throws -> MosaicJobResult {
        var request = URLRequest(url: endpoint("jobs/\(id)/result"))
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let data = try await perform(request, accepting: 200)
        return try decode(MosaicJobResult.self, from: data)
    }

    /// Download an artifact by its (possibly relative) URL string.
    func downloadArtifact(at urlString: String) async throws -> Data {
        guard let url = resolve(urlString) else {
            throw ServiceError.invalidArtifactURL
        }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return try await perform(request, accepting: 200)
    }

    /// Convenience: download and decode the `parts.json` artifact.
    func fetchPartsList(from result: MosaicJobResult) async throws -> MosaicPartsList {
        let data = try await downloadArtifact(at: result.partsURL)
        return try decode(MosaicPartsList.self, from: data)
    }

    /// Convenience: download the thumbnail artifact as a `UIImage`.
    func fetchThumbnail(from result: MosaicJobResult) async throws -> UIImage {
        let data = try await downloadArtifact(at: result.thumbnailURL)
        guard let image = UIImage(data: data) else {
            throw ServiceError.decodingFailed
        }
        return image
    }

    /// Resolve a relative (`/artifacts/...`) or absolute URL string against the
    /// configured base URL.
    nonisolated func resolve(_ urlString: String) -> URL? {
        if let absolute = URL(string: urlString), absolute.scheme != nil {
            return absolute
        }
        return URL(string: urlString, relativeTo: baseURL)?.absoluteURL
    }

    // MARK: - Networking Helpers

    private nonisolated var userAgent: String {
        "\(AppConfig.appName)/1.0 (iOS LEGO Mosaic Client)"
    }

    private func endpoint(_ path: String) -> URL {
        baseURL.appendingPathComponent(path)
    }

    /// Run a request, mapping transport failures to `.unreachable` and non-2xx
    /// responses to `.server`.
    private func perform(_ request: URLRequest, accepting expected: Int) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            Self.logger.error("Request to \(request.url?.absoluteString ?? "?") failed: \(error.localizedDescription)")
            throw ServiceError.unreachable
        }

        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.unreachable
        }
        guard http.statusCode == expected else {
            throw ServiceError.server(
                status: http.statusCode,
                message: extractServerMessage(from: data)
            )
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            Self.logger.error("Failed to decode \(String(describing: type)): \(error.localizedDescription)")
            throw ServiceError.decodingFailed
        }
    }

    /// FastAPI/Starlette error bodies use `{ "detail": "..." }`.
    private func extractServerMessage(from data: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let detail = object["detail"] as? String { return detail }
        if let message = object["message"] as? String { return message }
        return nil
    }

    private func encodeJPEG(_ image: UIImage) -> Data? {
        // The backend downsamples to MAX_SOURCE_DIM (1024 px); 0.85 quality is
        // ample and keeps uploads well under the 20 MB cap.
        if let data = image.jpegData(compressionQuality: 0.85),
           data.count <= AppConfig.mosaicMaxUploadBytes {
            return data
        }
        return image.jpegData(compressionQuality: 0.5)
    }

    private func appendField(
        _ body: inout Data,
        boundary: String,
        name: String,
        value: String
    ) {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(value)\r\n".data(using: .utf8)!)
    }

    private func appendFile(
        _ body: inout Data,
        boundary: String,
        name: String,
        filename: String,
        contentType: String,
        data: Data
    ) {
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n"
                .data(using: .utf8)!
        )
        body.append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n".data(using: .utf8)!)
    }
}
