import Foundation

/// Thin client for the OpenSubtitles.com REST API (v1). The app needs its own API key from
/// opensubtitles.com/consumers; downloads also need a user login. Both live in the keychain.
struct OpenSubtitlesClient {
    struct Result: Identifiable, Hashable, Sendable {
        let id: String
        let fileId: Int
        let title: String
        let year: Int?
        let release: String
        let language: String
        let fps: Double?
        let downloads: Int
        let hearingImpaired: Bool
        let season: Int?
        let episode: Int?
        let featureType: String
    }

    enum ClientError: LocalizedError {
        case missingKey
        case notLoggedIn
        case http(Int, String)
        case malformed

        var errorDescription: String? {
            switch self {
            case .missingKey: "Add your OpenSubtitles API key in Settings first."
            case .notLoggedIn: "Log in to OpenSubtitles in Settings to download subtitles."
            case .http(let code, let body): "OpenSubtitles replied \(code). \(body)"
            case .malformed: "OpenSubtitles sent something Subtext could not read."
            }
        }
    }

    static let base = URL(string: "https://api.opensubtitles.com/api/v1")!
    static let keyAccount = "opensubtitles.apiKey"
    static let tokenAccount = "opensubtitles.token"
    static let userAccount = "opensubtitles.username"
    static let passwordAccount = "opensubtitles.password"

    static var apiKey: String? { Keychain.get(keyAccount) }
    static var token: String? { Keychain.get(tokenAccount) }
    static var username: String? { Keychain.get(userAccount) }

    private func request(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: [String: Any]? = nil, authenticated: Bool = false) async throws -> Data {
        guard let key = Self.apiKey, !key.isEmpty else { throw ClientError.missingKey }
        var components = URLComponents(url: Self.base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var req = URLRequest(url: components.url!)
        req.httpMethod = method
        req.setValue(key, forHTTPHeaderField: "Api-Key")
        req.setValue("Subtext v0.1", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        if authenticated {
            guard let token = Self.token else { throw ClientError.notLoggedIn }
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String ?? ""
            throw ClientError.http(code, message)
        }
        return data
    }

    /// Logs in and stores the bearer token.
    func login(username: String, password: String) async throws {
        let data = try await request("login", method: "POST", body: ["username": username, "password": password])
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let token = json["token"] as? String else {
            throw ClientError.malformed
        }
        Keychain.set(token, for: Self.tokenAccount)
        Keychain.set(username, for: Self.userAccount)
        Keychain.set(password, for: Self.passwordAccount)
    }

    func search(query: String, languages: String, season: Int?, episode: Int?) async throws -> [Result] {
        var items = [URLQueryItem(name: "query", value: query), URLQueryItem(name: "languages", value: languages), URLQueryItem(name: "order_by", value: "download_count")]
        if let season { items.append(URLQueryItem(name: "season_number", value: String(season))) }
        if let episode { items.append(URLQueryItem(name: "episode_number", value: String(episode))) }
        let data = try await request("subtitles", query: items)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let rows = json["data"] as? [[String: Any]] else {
            throw ClientError.malformed
        }
        return rows.compactMap { row in
            guard let id = row["id"] as? String, let attrs = row["attributes"] as? [String: Any],
                  let files = attrs["files"] as? [[String: Any]], let fileId = files.first?["file_id"] as? Int else { return nil }
            let feature = attrs["feature_details"] as? [String: Any] ?? [:]
            return Result(
                id: id,
                fileId: fileId,
                title: feature["title"] as? String ?? feature["movie_name"] as? String ?? query,
                year: feature["year"] as? Int,
                release: attrs["release"] as? String ?? "",
                language: attrs["language"] as? String ?? languages,
                fps: attrs["fps"] as? Double,
                downloads: attrs["download_count"] as? Int ?? 0,
                hearingImpaired: attrs["hearing_impaired"] as? Bool ?? false,
                season: feature["season_number"] as? Int,
                episode: feature["episode_number"] as? Int,
                featureType: feature["feature_type"] as? String ?? ""
            )
        }
    }

    /// Resolves a download link and fetches the subtitle file. Re-logs in once on a stale token.
    func download(fileId: Int) async throws -> (data: Data, filename: String) {
        do {
            return try await downloadOnce(fileId: fileId)
        } catch ClientError.http(let code, _) where code == 401 || code == 403 {
            if let user = Self.username, let password = Keychain.get(Self.passwordAccount) {
                try await login(username: user, password: password)
                return try await downloadOnce(fileId: fileId)
            }
            throw ClientError.notLoggedIn
        }
    }

    private func downloadOnce(fileId: Int) async throws -> (Data, String) {
        let data = try await request("download", method: "POST", body: ["file_id": fileId, "sub_format": "srt"], authenticated: true)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let link = json["link"] as? String, let url = URL(string: link) else { throw ClientError.malformed }
        let (file, _) = try await URLSession.shared.data(from: url)
        let name = json["file_name"] as? String ?? url.lastPathComponent
        return (file, name)
    }
}
