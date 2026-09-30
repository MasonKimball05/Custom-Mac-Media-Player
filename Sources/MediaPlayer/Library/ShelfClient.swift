import Foundation

// Client for shelf, the media server on the desktop (github.com/MasonKimball05/shelf),
// reached over Tailscale.
//
// Library items are stored in the playlist as stable `shelf://<file-id>/<name>`
// URLs. The server's real stream links are signed and expire, so they're fetched
// fresh each time an item plays (`link(forItemURL:)`) and never saved: resume
// positions, recents and saved playlists all key off the stable shelf:// form.

struct ShelfFile: Codable, Identifiable, Hashable {
    let id: String
    let root: String
    let path: String
    let name: String
    let kind: String
    let size: Int64

    var isVideo: Bool { kind == "video" }
}

struct ShelfListing: Codable {
    let root: String
    let path: String
    let dirs: [String]
    let files: [ShelfFile]
}

struct ShelfRoots: Codable {
    let roots: [String]
    let files: Int
}

struct ShelfLink: Codable {
    let url: String
    let name: String
    let size: Int64
    let expires: Int64
    let subtitles: [ShelfLink]?
}

enum ShelfError: LocalizedError {
    case notConfigured
    case offline
    case unauthorized
    case notFound
    case server(Int)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Set up your media library in Settings \u{2192} Library."
        case .offline: return "Can\u{2019}t reach the desktop. It may be off, asleep, or not on Tailscale."
        case .unauthorized: return "The library rejected the access token. Check it in Settings \u{2192} Library."
        case .notFound: return "That file isn\u{2019}t in the library anymore."
        case .server(let code): return "The library server returned an error (HTTP \(code))."
        case .badResponse: return "The library server sent something unexpected."
        }
    }
}

final class ShelfClient: @unchecked Sendable {
    static let shared = ShelfClient()
    static let scheme = "shelf"
    static let keychainAccount = "shelf-token"

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    var baseURL: URL? {
        guard let raw = UserDefaults.standard.string(forKey: AppSettingsKeys.shelfServerURL)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    var isConfigured: Bool { baseURL != nil && Keychain.read(account: Self.keychainAccount) != nil }

    // MARK: Stable item URLs

    static func itemURL(for file: ShelfFile) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = file.id
        components.path = "/" + file.name
        return components.url
    }

    static func isShelfURL(_ url: URL) -> Bool { url.scheme == scheme }

    // MARK: API

    func roots() async throws -> ShelfRoots {
        try await request("GET", "api/roots")
    }

    func browse(root: String, path: String) async throws -> ShelfListing {
        try await request("GET", "api/browse", query: [.init(name: "root", value: root), .init(name: "path", value: path)])
    }

    func search(_ query: String) async throws -> [ShelfFile] {
        struct Results: Codable { let results: [ShelfFile] }
        let r: Results = try await request("GET", "api/search", query: [.init(name: "q", value: query)])
        return r.results
    }

    /// A fresh signed stream link for a stable shelf:// item URL.
    func link(forItemURL url: URL) async throws -> ShelfLink {
        guard Self.isShelfURL(url), let id = url.host, !id.isEmpty else { throw ShelfError.notFound }
        return try await request("POST", "api/link", query: [.init(name: "id", value: id)])
    }

    private func request<T: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = []) async throws -> T {
        guard let base = baseURL, let token = Keychain.read(account: Self.keychainAccount) else {
            throw ShelfError.notConfigured
        }
        guard var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw ShelfError.notConfigured
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw ShelfError.notConfigured }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let error as URLError {
            switch error.code {
            case .cannotConnectToHost, .cannotFindHost, .timedOut, .notConnectedToInternet,
                 .networkConnectionLost, .dnsLookupFailed:
                throw ShelfError.offline
            default:
                throw error
            }
        }
        guard let http = response as? HTTPURLResponse else { throw ShelfError.badResponse }
        switch http.statusCode {
        case 200: break
        case 401: throw ShelfError.unauthorized
        case 404: throw ShelfError.notFound
        default: throw ShelfError.server(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ShelfError.badResponse
        }
    }
}
