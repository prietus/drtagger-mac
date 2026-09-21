import Foundation

// iTunes Search API (no key). Album artwork is served at any size by
// rewriting the "100x100bb" suffix, up to 3000 px for most releases.
public actor ITunesSearchClient {

    public struct Album: Sendable, Equatable, Codable, Hashable {
        public let collectionID: Int
        public let artist: String
        public let title: String
        public let releaseDate: String?
        public let trackCount: Int?
        public let country: String?
        public let artworkURL100: URL
        public var artworkURL3000: URL { ITunesSearchClient.resize(artworkURL100, to: 3000) }
        public var artworkURL1500: URL { ITunesSearchClient.resize(artworkURL100, to: 1500) }
    }

    public let userAgent: String
    private let session: URLSession

    public init(userAgent: String, session: URLSession = .shared) {
        self.userAgent = userAgent
        self.session = session
    }

    public func searchAlbums(artist: String, album: String, country: String = "us", limit: Int = 10) async throws -> [Album] {
        let term = [artist, album].filter { !$0.isEmpty }.joined(separator: " ")
        guard !term.isEmpty else { return [] }
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        guard let url = components.url else { throw ProviderError.invalidURL }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 { throw ProviderError.httpError(http.statusCode) }
        return try Self.parse(data)
    }

    nonisolated static func parse(_ data: Data) throws -> [Album] {
        let root = try JSONDecoder().decode(ITunesResponse.self, from: data)
        return root.results.compactMap { r in
            guard let id = r.collectionId, let art = r.artworkUrl100.flatMap(URL.init(string:)) else { return nil }
            return Album(
                collectionID: id,
                artist: r.artistName ?? "",
                title: r.collectionName ?? "",
                releaseDate: r.releaseDate.map { String($0.prefix(10)) },
                trackCount: r.trackCount,
                country: r.country,
                artworkURL100: art
            )
        }
    }

    nonisolated static func resize(_ url: URL, to size: Int) -> URL {
        let s = url.absoluteString.replacingOccurrences(of: #"\d+x\d+bb"#, with: "\(size)x\(size)bb", options: .regularExpression)
        return URL(string: s) ?? url
    }
}

private struct ITunesResponse: Decodable {
    let results: [ITunesAlbum]
}

private struct ITunesAlbum: Decodable {
    let collectionId: Int?
    let artistName: String?
    let collectionName: String?
    let releaseDate: String?
    let trackCount: Int?
    let country: String?
    let artworkUrl100: String?
}
