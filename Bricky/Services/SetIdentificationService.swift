import Foundation
import UIKit
import os.log

/// Errors surfaced to the user during AI set identification. All carry honest,
/// localized messages — we never fabricate a set on failure.
enum SetIdentificationError: LocalizedError, Equatable {
    case notConfigured
    case offline
    case notEntitled
    case quotaExceeded
    case imageEncodingFailed
    case server(status: Int, message: String?)
    case decoding
    case noSetIdentified

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return L10n.setIdErrorNotConfigured
        case .offline:
            return L10n.setIdErrorOffline
        case .notEntitled:
            return L10n.setIdErrorNotEntitled
        case .quotaExceeded:
            return L10n.setIdErrorQuotaExceeded
        case .imageEncodingFailed:
            return L10n.setIdErrorImageEncoding
        case .server(_, let message):
            return message ?? L10n.setIdErrorServer
        case .decoding:
            return L10n.setIdErrorServer
        case .noSetIdentified:
            return L10n.setIdEmptyMessage
        }
    }
}

/// Identifies which official LEGO set an already-built model is, from a photo.
/// Hidden, developer-only, network-backed (GPT-4o vision via the proxy).
protocol SetIdentificationService: Sendable {
    /// Identify the set in `image`. Caller must pass a valid developer-bypass
    /// entitlement proof (`entitlementToken`) which the proxy verifies before
    /// spending an Azure call.
    func identify(in image: UIImage, entitlementToken: String) async throws -> SetIdentificationResult
}

/// Production implementation. Calls the Bricky recognition **proxy** (an Azure
/// Function) which holds the Azure OpenAI key, verifies the developer
/// entitlement server-side, enforces the monthly quota, and calls GPT-4o
/// vision. The Azure key is NEVER shipped in the app.
struct AzureOpenAISetClient: SetIdentificationService {

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? AppConfig.bundleId,
        category: "SetIdentification"
    )

    private let endpoint: URL?
    private let httpClient: RecognitionHTTPClient

    init(
        endpoint: URL? = AppConfig.setIdentificationEndpoint,
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

    func identify(in image: UIImage, entitlementToken: String) async throws -> SetIdentificationResult {
        guard let endpoint else {
            throw SetIdentificationError.notConfigured
        }
        guard let jpeg = Self.downscaledJPEG(image) else {
            throw SetIdentificationError.imageEncodingFailed
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
            throw SetIdentificationError.offline
        } catch {
            throw SetIdentificationError.server(status: -1, message: nil)
        }

        guard let http = response as? HTTPURLResponse else {
            throw SetIdentificationError.decoding
        }

        switch http.statusCode {
        case 200:
            break
        case 401, 403:
            throw SetIdentificationError.notEntitled
        case 429:
            throw SetIdentificationError.quotaExceeded
        default:
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
            throw SetIdentificationError.server(status: http.statusCode, message: message)
        }

        let result: SetIdentificationResult
        do {
            result = try JSONDecoder().decode(SetIdentificationResult.self, from: data)
        } catch {
            Self.logger.error("Failed to decode set identification response")
            throw SetIdentificationError.decoding
        }

        guard !result.isEmpty else {
            throw SetIdentificationError.noSetIdentified
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
    /// request small and cheap on Azure's per-image pricing.
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
