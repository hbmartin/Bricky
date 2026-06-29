import Foundation

/// Fetches the *full* parts list (bill of materials) for a LEGO set from
/// Rebrickable's public API using a user-supplied personal key. This replaces
/// the bundled representative sample so set completion is computed against the
/// real inventory. The key lives only on-device (see `AppConfig.rebrickableAPIKey`);
/// no key is shipped with the app and there is no server cost.
enum RebrickableSetError: LocalizedError, Equatable {
    case notConfigured
    case offline
    case unauthorized
    case notFound
    case server(status: Int)
    case decoding

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Add a Rebrickable API key in Settings to fetch full set parts."
        case .offline: return "You appear to be offline."
        case .unauthorized: return "Rebrickable rejected the API key. Check it in Settings."
        case .notFound: return "Rebrickable has no parts list for this set."
        case .server(let s): return "Rebrickable returned an error (\(s))."
        case .decoding: return "Could not read the parts list from Rebrickable."
        }
    }
}

struct RebrickableSetService {
    private let apiKey: String?
    private let proxyEndpoint: URL?
    private let session: URLSession

    init(apiKey: String? = AppConfig.rebrickableAPIKey,
         proxyEndpoint: URL? = AppConfig.setPartsEndpoint,
         session: URLSession = .shared) {
        self.apiKey = apiKey
        self.proxyEndpoint = proxyEndpoint
        self.session = session
    }

    /// Configured when either the server proxy or a personal key is available.
    var isConfigured: Bool { proxyEndpoint != nil || apiKey != nil }

    // MARK: - Wire types

    private struct PartsPage: Decodable {
        let next: String?
        let results: [Row]
    }

    private struct Row: Decodable {
        let quantity: Int
        let is_spare: Bool
        let part: Part
        let color: Color
        struct Part: Decodable { let part_num: String }
        struct Color: Decodable { let name: String }
    }

    private struct ProxyResponse: Decodable {
        let pieces: [ProxyPiece]
        struct ProxyPiece: Decodable { let partNumber: String; let color: String; let quantity: Int }
    }

    /// Fetch every part for `setNumber`. Tries the proxy (Key Vault key) first;
    /// falls back to the user's personal key when the proxy has none.
    func fetchParts(for setNumber: String) async throws -> [LegoSet.SetPiece] {
        if let pieces = try await fetchViaProxy(setNumber) { return pieces }
        return try await fetchViaPersonalKey(setNumber)
    }

    private func fetchViaProxy(_ setNumber: String) async throws -> [LegoSet.SetPiece]? {
        guard let proxyEndpoint else { return nil }
        let base = LegoSetCatalog.normalizeSetNumber(setNumber)
        guard var comps = URLComponents(url: proxyEndpoint, resolvingAgainstBaseURL: false) else { return nil }
        comps.queryItems = [URLQueryItem(name: "set", value: base)]
        guard let url = comps.url else { return nil }

        let data: Data; let resp: URLResponse
        do { (data, resp) = try await session.data(from: url) }
        catch let e as URLError where [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(e.code) {
            throw RebrickableSetError.offline
        }
        guard let http = resp as? HTTPURLResponse else { throw RebrickableSetError.decoding }
        switch http.statusCode {
        case 200:
            guard let decoded = try? JSONDecoder().decode(ProxyResponse.self, from: data) else {
                throw RebrickableSetError.decoding
            }
            return decoded.pieces.map { .init(partNumber: $0.partNumber, color: Self.mappedColor($0.color), quantity: $0.quantity) }
        case 404: throw RebrickableSetError.notFound
        default: return nil // proxy has no key / error — fall back to personal key
        }
    }

    private func fetchViaPersonalKey(_ setNumber: String) async throws -> [LegoSet.SetPiece] {
        guard let apiKey else { throw RebrickableSetError.notConfigured }
        let base = LegoSetCatalog.normalizeSetNumber(setNumber)
        var url = URL(string: "https://rebrickable.com/api/v3/lego/sets/\(base)-1/parts/?page_size=1000")

        var combined: [String: LegoSet.SetPiece] = [:]
        while let next = url {
            var req = URLRequest(url: next)
            req.setValue("key \(apiKey)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Accept")

            let data: Data
            let resp: URLResponse
            do {
                (data, resp) = try await session.data(for: req)
            } catch let e as URLError where [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(e.code) {
                throw RebrickableSetError.offline
            }
            guard let http = resp as? HTTPURLResponse else { throw RebrickableSetError.decoding }
            switch http.statusCode {
            case 200: break
            case 401, 403: throw RebrickableSetError.unauthorized
            case 404: throw RebrickableSetError.notFound
            default: throw RebrickableSetError.server(status: http.statusCode)
            }
            guard let page = try? JSONDecoder().decode(PartsPage.self, from: data) else {
                throw RebrickableSetError.decoding
            }
            for row in page.results where !row.is_spare {
                let color = Self.mappedColor(row.color.name)
                let key = "\(row.part.part_num)|\(color)"
                if let existing = combined[key] {
                    combined[key] = .init(partNumber: existing.partNumber, color: color,
                                          quantity: existing.quantity + row.quantity)
                } else {
                    combined[key] = .init(partNumber: row.part.part_num, color: color, quantity: row.quantity)
                }
            }
            url = page.next.flatMap { URL(string: $0) }
        }
        return Array(combined.values)
    }

    /// Map common Rebrickable color names to the app's `LegoColor` raw values so
    /// fetched BOMs can match scanned inventory. Unmapped names pass through.
    static func mappedColor(_ name: String) -> String {
        switch name {
        case "Light Bluish Gray", "Light Gray": return "Gray"
        case "Dark Bluish Gray": return "Dark Gray"
        case "Reddish Brown": return "Brown"
        case "Bright Green": return "Green"
        case "Trans-Clear": return "Transparent"
        case "Trans-Red": return "Transparent Red"
        case "Trans-Blue": return "Trans Blue"
        default: return name
        }
    }
}
