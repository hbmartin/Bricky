import Foundation

/// Set Forge Phase 2 — text → voxel model via the cloud proxy (GPT-4o).
///
/// Calls the Bricky recognition **proxy** (an Azure Function) which holds the
/// Azure OpenAI key, verifies the developer entitlement server-side, enforces
/// the monthly quota, and asks GPT-4o to author a brick-compatible voxel model.
/// The Azure key is NEVER shipped in the app.
///
/// This is a hidden, developer-only cloud feature. When it's not available
/// (not entitled, offline, or not deployed), callers fall back to the on-device
/// `VoxelShapeLibrary` — the feature degrades gracefully and never fabricates.
protocol SetForgeTextService: Sendable {
    /// Forge a voxel model for `prompt`. `entitlementToken` is the developer
    /// bypass proof the proxy verifies before spending an Azure call.
    func generateModel(
        prompt: String,
        size: VoxelModel.Size,
        entitlementToken: String
    ) async throws -> VoxelModel
}

/// Errors from the cloud forge path. All honest; callers may fall back to the
/// on-device generator rather than surfacing these.
enum SetForgeTextError: LocalizedError, Equatable {
    case notConfigured
    case offline
    case notEntitled
    case quotaExceeded
    case server(status: Int, message: String?)
    case decoding
    case emptyModel

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Cloud model generation isn't set up."
        case .offline: return "You appear to be offline."
        case .notEntitled: return "Cloud model generation isn't available."
        case .quotaExceeded: return "You've reached this month's cloud limit."
        case .server(_, let message): return message ?? "The model service had a problem."
        case .decoding: return "The model service returned an unexpected response."
        case .emptyModel: return "Couldn't design a model for that description."
        }
    }
}

/// Production implementation. POSTs `{ prompt, size, entitlementToken }` to the
/// proxy and decodes the expanded voxel list into a `VoxelModel`.
struct AzureOpenAIForgeTextClient: SetForgeTextService {

    private let endpoint: URL?
    private let httpClient: RecognitionHTTPClient

    init(
        endpoint: URL? = AppConfig.forgeFromTextEndpoint,
        httpClient: RecognitionHTTPClient = Self.makeDefaultSession()
    ) {
        self.endpoint = endpoint
        self.httpClient = httpClient
    }

    private static func makeDefaultSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 90
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }

    // MARK: - Wire types

    private struct RequestBody: Encodable {
        let prompt: String
        let size: String
        let entitlementToken: String
    }

    private struct WireVoxel: Decodable {
        let x: Int
        let y: Int
        let z: Int
        let color: String
    }

    private struct ResponseBody: Decodable {
        let width: Int
        let height: Int
        let depth: Int
        let voxels: [WireVoxel]
        let subject: String
    }

    private struct ErrorBody: Decodable {
        let error: String?
        let code: String?
    }

    private func sizeWire(_ size: VoxelModel.Size) -> String {
        switch size {
        case .small: return "small"
        case .medium: return "medium"
        case .large: return "large"
        }
    }

    func generateModel(
        prompt: String,
        size: VoxelModel.Size,
        entitlementToken: String
    ) async throws -> VoxelModel {
        guard let endpoint else { throw SetForgeTextError.notConfigured }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            RequestBody(
                prompt: prompt,
                size: sizeWire(size),
                entitlementToken: entitlementToken
            )
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await httpClient.send(request)
        } catch let urlError as URLError where Self.isOfflineError(urlError) {
            throw SetForgeTextError.offline
        } catch {
            throw SetForgeTextError.server(status: -1, message: nil)
        }

        guard let http = response as? HTTPURLResponse else {
            throw SetForgeTextError.decoding
        }

        switch http.statusCode {
        case 200:
            break
        case 401, 403:
            throw SetForgeTextError.notEntitled
        case 429:
            throw SetForgeTextError.quotaExceeded
        case 422:
            throw SetForgeTextError.emptyModel
        default:
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
            throw SetForgeTextError.server(status: http.statusCode, message: message)
        }

        let body: ResponseBody
        do {
            body = try JSONDecoder().decode(ResponseBody.self, from: data)
        } catch {
            throw SetForgeTextError.decoding
        }

        let voxels: [Voxel] = body.voxels.compactMap { wire in
            guard let color = LegoColor(fromString: wire.color) else { return nil }
            return Voxel(x: wire.x, y: wire.y, z: wire.z, color: color)
        }
        guard !voxels.isEmpty else { throw SetForgeTextError.emptyModel }

        return VoxelModel(
            width: body.width,
            height: body.height,
            depth: body.depth,
            voxels: voxels,
            source: .text,
            subject: body.subject
        )
    }

    private static func isOfflineError(_ error: URLError) -> Bool {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost,
             .cannotConnectToHost, .timedOut, .dataNotAllowed:
            return true
        default:
            return false
        }
    }
}
