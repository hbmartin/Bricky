import Foundation
import UIKit
import os.log

/// Abstraction over the network call so tests can mock *only* the transport
/// boundary — never the production UI or business logic.
protocol RecognitionHTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: RecognitionHTTPClient {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request)
    }
}

/// Errors surfaced to the user during AI subject recognition. All carry honest,
/// localized messages — we never fabricate a result on failure.
enum ImageRecognitionError: LocalizedError, Equatable {
    case notConfigured
    case offline
    case notEntitled
    case quotaExceeded
    case imageEncodingFailed
    case server(status: Int, message: String?)
    case decoding
    case noSubjectsFound

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return L10n.recognitionErrorNotConfigured
        case .offline:
            return L10n.recognitionErrorOffline
        case .notEntitled:
            return L10n.recognitionErrorNotEntitled
        case .quotaExceeded:
            return L10n.recognitionErrorQuotaExceeded
        case .imageEncodingFailed:
            return L10n.recognitionErrorImageEncoding
        case .server(_, let message):
            return message ?? L10n.recognitionErrorServer
        case .decoding:
            return L10n.recognitionErrorServer
        case .noSubjectsFound:
            return L10n.recognitionEmptyMessage
        }
    }
}

/// Identifies real-world subjects (celebrities, cartoon characters, famous
/// places/landmarks, musicians, etc.) in a photo. Pro-gated, network-backed.
protocol ImageRecognitionService: Sendable {
    /// Recognize subjects in `image`. Caller must pass a valid StoreKit
    /// entitlement proof (`entitlementToken`) which the proxy verifies before
    /// spending an Azure call.
    func recognize(in image: UIImage, entitlementToken: String) async throws -> RecognitionResult
}

/// Production implementation. Calls the Bricky recognition **proxy** (an Azure
/// Function) which holds the Azure OpenAI key, verifies the StoreKit
/// entitlement server-side, enforces the monthly quota, and calls GPT-4o
/// vision. The Azure key is NEVER shipped in the app.
struct AzureOpenAIRecognitionClient: ImageRecognitionService {

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? AppConfig.bundleId,
        category: "ImageRecognition"
    )

    private let endpoint: URL?
    private let httpClient: RecognitionHTTPClient

    init(
        endpoint: URL? = AppConfig.aiRecognitionEndpoint,
        httpClient: RecognitionHTTPClient = makeDefaultSession()
    ) {
        self.endpoint = endpoint
        self.httpClient = httpClient
    }

    private static func makeDefaultSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }

    // MARK: - Request / Response wire types

    private struct RequestBody: Encodable {
        let imageBase64: String
        let entitlementToken: String
    }

    private struct ErrorBody: Decodable {
        let error: String?
        let code: String?
    }

    func recognize(in image: UIImage, entitlementToken: String) async throws -> RecognitionResult {
        guard let endpoint else {
            throw ImageRecognitionError.notConfigured
        }
        // Downscale to keep upload (and Azure image cost) small; GPT-4o vision
        // doesn't need full resolution to recognize famous subjects.
        guard let jpeg = Self.downscaledJPEG(image) else {
            throw ImageRecognitionError.imageEncodingFailed
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            RequestBody(
                imageBase64: jpeg.base64EncodedString(),
                entitlementToken: entitlementToken
            )
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await httpClient.send(request)
        } catch let urlError as URLError where Self.isOfflineError(urlError) {
            throw ImageRecognitionError.offline
        } catch {
            throw ImageRecognitionError.server(status: -1, message: nil)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ImageRecognitionError.decoding
        }

        switch http.statusCode {
        case 200:
            break
        case 401, 403:
            throw ImageRecognitionError.notEntitled
        case 429:
            throw ImageRecognitionError.quotaExceeded
        default:
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
            throw ImageRecognitionError.server(status: http.statusCode, message: message)
        }

        let result: RecognitionResult
        do {
            result = try JSONDecoder().decode(RecognitionResult.self, from: data)
        } catch {
            Self.logger.error("Failed to decode recognition response")
            throw ImageRecognitionError.decoding
        }

        guard !result.isEmpty else {
            throw ImageRecognitionError.noSubjectsFound
        }
        return result
    }

    // MARK: - Helpers

    private static func isOfflineError(_ error: URLError) -> Bool {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost,
             .cannotConnectToHost, .timedOut, .dataNotAllowed:
            return true
        default:
            return false
        }
    }

    /// Resize so the longest edge is at most 1024px, then JPEG-encode. Keeps the
    /// request small enough to be fast and cheap on Azure's per-image pricing.
    private static func downscaledJPEG(_ image: UIImage, maxEdge: CGFloat = 1024) -> Data? {
        let size = image.size
        let longest = max(size.width, size.height)
        let scaled: UIImage
        if longest > maxEdge, longest > 0 {
            let ratio = maxEdge / longest
            let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)
            let renderer = UIGraphicsImageRenderer(size: newSize)
            scaled = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: newSize))
            }
        } else {
            scaled = image
        }
        return scaled.jpegData(compressionQuality: 0.8)
    }
}
