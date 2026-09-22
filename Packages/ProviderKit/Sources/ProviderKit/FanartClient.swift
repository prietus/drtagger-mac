import Foundation

// fanart.tv: high-resolution album covers keyed by MusicBrainz release
// group. Needs a project API key the user requests at fanart.tv.
public actor FanartClient {

    public struct Cover: Sendable, Equatable, Codable, Hashable {
        public let url: URL
        public let likes: Int
    }

    public let apiKey: String
    public let userAgent: String
    private let session: URLSession

    public init(apiKey: String, userAgent: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.userAgent = userAgent
        self.session = session
    }

    public func albumCovers(releaseGroupID: String) async throws -> [Cover] {
        var components = URLComponents(string: "https://webservice.fanart.tv/v3/music/albums/\(releaseGroupID)")!
        components.queryItems = [URLQueryItem(name: "api_key", value: apiKey)]
        guard let url = components.url else { throw ProviderError.invalidURL }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse {
            if http.statusCode == 404 { return [] }
            if http.statusCode >= 400 { throw ProviderError.httpError(http.statusCode) }
        }
        return Self.parse(data, releaseGroupID: releaseGroupID)
    }

    // {"albums": {"<rgid>": {"albumcover": [{"id": "…", "url": "…", "likes": "3"}], "cdart": […]}}}
    static func parse(_ data: Data, releaseGroupID: String) -> [Cover] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let albums = root["albums"] as? [String: Any] else { return [] }
        let album = (albums[releaseGroupID] as? [String: Any]) ?? (albums.values.first as? [String: Any]) ?? [:]
        let covers = (album["albumcover"] as? [[String: Any]]) ?? []
        return covers.compactMap { c -> Cover? in
            guard let s = c["url"] as? String, let url = URL(string: s) else { return nil }
            let likes = (c["likes"] as? String).flatMap(Int.init) ?? (c["likes"] as? Int) ?? 0
            return Cover(url: url, likes: likes)
        }.sorted { $0.likes > $1.likes }
    }
}
