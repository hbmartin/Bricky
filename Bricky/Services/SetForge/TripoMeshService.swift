import Foundation

/// Set Forge premium tier — text → high-fidelity 3D **mesh** via the cloud proxy
/// (hosted Tripo). Returns a **local file URL** to a downloaded model that the
/// caller voxelizes on-device with `MeshVoxelizer`.
///
/// Developer-only cloud feature (cost-controlled), same as the other cloud
/// paths. Only formats Model I/O can read are accepted (`usdz`/`obj`/`ply`/
/// `stl`); anything else throws so the caller can fall back to the GPT voxel
/// path and then the on-device library. Never fabricates.
protocol SetForgeMeshService: Sendable {
    /// Forge and download a 3D model from a text prompt; returns a local file URL.
    func generateMesh(
        prompt: String,
        size: VoxelModel.Size,
        entitlementToken: String
    ) async throws -> URL

    /// Forge and download a 3D model from an image; returns a local file URL.
    func generateMesh(
        imageData: Data,
        mime: String,
        size: VoxelModel.Size,
        entitlementToken: String
    ) async throws -> URL
}

enum SetForgeMeshError: LocalizedError, Equatable {
    case notConfigured
    case offline
    case notEntitled
    case quotaExceeded
    case server(status: Int, message: String?)
    case decoding
    case unsupportedFormat(String)
    case emptyModel

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Cloud model generation isn't set up."
        case .offline: return "You appear to be offline."
        case .notEntitled: return "Cloud model generation isn't available."
        case .quotaExceeded: return "The HD model service is at capacity."
        case .server(_, let message): return message ?? "The model service had a problem."
        case .decoding: return "The model service returned an unexpected response."
        case .unsupportedFormat(let f): return "The model came back in an unsupported format (.\(f))."
        case .emptyModel: return "Couldn't generate a model for that description."
        }
    }
}

struct AzureTripoMeshClient: SetForgeMeshService {

    /// Formats `MeshVoxelizer` (Model I/O) can read.
    static let supportedFormats: Set<String> = ["usdz", "usdc", "usd", "obj", "ply", "stl"]

    private let endpoint: URL?
    private let imageEndpoint: URL?
    private let httpClient: RecognitionHTTPClient

    init(
        endpoint: URL? = AppConfig.forgeMeshFromTextEndpoint,
        imageEndpoint: URL? = AppConfig.forgeMeshFromImageEndpoint,
        httpClient: RecognitionHTTPClient = Self.makeDefaultSession()
    ) {
        self.endpoint = endpoint
        self.imageEndpoint = imageEndpoint
        self.httpClient = httpClient
    }

    private static func makeDefaultSession() -> URLSession {
        let config = URLSessionConfiguration.default
        // Generation + download can take a while (vendor queue + polling).
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 240
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }

    private struct RequestBody: Encodable {
        let prompt: String
        let size: String
        let entitlementToken: String
    }

    private struct ImageRequestBody: Encodable {
        let imageBase64: String
        let mime: String
        let size: String
        let entitlementToken: String
    }

    private struct ResponseBody: Decodable {
        let modelUrl: String
        let format: String
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

    func generateMesh(
        prompt: String,
        size: VoxelModel.Size,
        entitlementToken: String
    ) async throws -> URL {
        guard let endpoint else { throw SetForgeMeshError.notConfigured }
        let body = RequestBody(prompt: prompt, size: sizeWire(size), entitlementToken: entitlementToken)
        return try await forge(endpoint: endpoint, body: body)
    }

    func generateMesh(
        imageData: Data,
        mime: String,
        size: VoxelModel.Size,
        entitlementToken: String
    ) async throws -> URL {
        guard let imageEndpoint else { throw SetForgeMeshError.notConfigured }
        let body = ImageRequestBody(
            imageBase64: imageData.base64EncodedString(),
            mime: mime,
            size: sizeWire(size),
            entitlementToken: entitlementToken
        )
        return try await forge(endpoint: imageEndpoint, body: body)
    }

    // MARK: - Shared forge + download

    private func forge<Body: Encodable>(endpoint: URL, body: Body) async throws -> URL {
        // 1. Ask the proxy to forge the model (it polls the vendor server-side).
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await sendMapped(request)
        try Self.checkStatus(response, data: data)

        let decoded: ResponseBody
        do {
            decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        } catch {
            throw SetForgeMeshError.decoding
        }

        let format = decoded.format.lowercased()
        guard Self.supportedFormats.contains(format) else {
            throw SetForgeMeshError.unsupportedFormat(format)
        }
        guard let modelURL = URL(string: decoded.modelUrl) else {
            throw SetForgeMeshError.emptyModel
        }

        // 2. Download the model file to a temp location.
        var download = URLRequest(url: modelURL)
        download.httpMethod = "GET"
        let (fileData, fileResponse) = try await sendMapped(download)
        if let http = fileResponse as? HTTPURLResponse, http.statusCode != 200 {
            throw SetForgeMeshError.server(status: http.statusCode, message: nil)
        }
        guard !fileData.isEmpty else { throw SetForgeMeshError.emptyModel }

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(format)
        try fileData.write(to: temp, options: .atomic)
        return temp
    }

    // MARK: - Helpers

    private func sendMapped(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await httpClient.send(request)
        } catch let urlError as URLError where Self.isOfflineError(urlError) {
            throw SetForgeMeshError.offline
        } catch {
            throw SetForgeMeshError.server(status: -1, message: nil)
        }
    }

    private static func checkStatus(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw SetForgeMeshError.decoding }
        switch http.statusCode {
        case 200: return
        case 401, 403: throw SetForgeMeshError.notEntitled
        case 429: throw SetForgeMeshError.quotaExceeded
        case 422: throw SetForgeMeshError.emptyModel
        default:
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
            throw SetForgeMeshError.server(status: http.statusCode, message: message)
        }
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
