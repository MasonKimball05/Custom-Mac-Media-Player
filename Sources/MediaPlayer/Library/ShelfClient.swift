import AppKit

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
    /// Where playback last stopped, on any Mac, and the file's length (seconds).
    /// Missing when it hasn't been started or was watched to the end.
    let position: Double?
    let duration: Double?

    var isVideo: Bool { kind == "video" }

    /// 0...1 for a progress bar, when both numbers are known.
    var watchedFraction: Double? {
        guard let position, let duration, duration > 0 else { return nil }
        return min(max(position / duration, 0), 1)
    }
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
    /// Where playback last stopped, on any Mac.
    let position: Double?
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
        guard let id = Self.fileID(of: url) else { throw ShelfError.notFound }
        return try await request("POST", "api/link", query: [.init(name: "id", value: id)])
    }

    /// The file ID inside a stable shelf:// item URL.
    static func fileID(of url: URL) -> String? {
        guard isShelfURL(url), let id = url.host, !id.isEmpty else { return nil }
        return id
    }

    /// A video's poster frame as JPEG data. Throws `.notFound` for files without one
    /// (audio, unreadable video) and when the server has no ffmpeg.
    func thumbnail(id: String) async throws -> Data {
        // The first view of a folder makes the server run ffmpeg for each video (two at
        // a time), so later rows can wait longer than the API's usual 8 seconds.
        try await send("GET", "api/thumb", query: [.init(name: "id", value: id)], timeout: 60)
    }

    /// Saves where playback is in a library file, so it resumes there on any Mac.
    func saveProgress(id: String, position: Double, duration: Double) async throws {
        struct Body: Encodable { let id: String; let position: Double; let duration: Double }
        let body = try JSONEncoder().encode(Body(id: id, position: position, duration: duration))
        _ = try await send("POST", "api/progress", body: body)
    }

    private func request<T: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await send(method, path, query: query)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ShelfError.badResponse
        }
    }

    private func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil,
                      timeout: TimeInterval? = nil) async throws -> Data {
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
        if let timeout { req.timeoutInterval = timeout }
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

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
        case 200..<300: return data
        case 401: throw ShelfError.unauthorized
        case 404: throw ShelfError.notFound
        default: throw ShelfError.server(http.statusCode)
        }
    }
}

/// Library poster frames for the sidebar, kept in memory for the session. Files
/// without one (audio, unreadable video, no ffmpeg on the desktop) are remembered
/// too, so rows scrolling back into view don't ask again. Network failures aren't:
/// those are retried the next time the row appears.
@MainActor
final class ShelfThumbnails {
    static let shared = ShelfThumbnails()

    private let images = NSCache<NSString, NSImage>()
    private var missing = Set<String>()
    private var loading: [String: Task<NSImage?, Never>] = [:]

    func cached(_ id: String) -> NSImage? { images.object(forKey: id as NSString) }

    func image(for id: String) async -> NSImage? {
        if let image = cached(id) { return image }
        if missing.contains(id) { return nil }
        if let task = loading[id] { return await task.value }

        let task = Task { [weak self] () -> NSImage? in
            do {
                let data = try await ShelfClient.shared.thumbnail(id: id)
                return NSImage(data: data)
            } catch ShelfError.notFound {
                self?.missing.insert(id)
                return nil
            } catch {
                return nil
            }
        }
        loading[id] = task
        let image = await task.value
        loading[id] = nil
        if let image { images.setObject(image, forKey: id as NSString) }
        return image
    }
}
