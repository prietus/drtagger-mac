import Foundation

// Deezer public API (no key): album search with 1000 px covers.
public actor DeezerClient {

    public struct Album: Sendable, Equatable, Codable, Hashable {
        public let id: Int
        public let artist: String
        public let title: String
        public let trackCount: Int?
        public let coverXL: URL?      // 1000 px
        public let coverBig: URL?     // 500 px
    }

    public let userAgent: String
    private let session: URLSession

    public init(userAgent: String, session: URLSession = .shared) {
        self.userAgent = userAgent
        self.session = session
    }

    public func searchAlbums(artist: String, album: String, limit: Int = 10) async throws -> [Album] {
        var parts: [String] = []
        if !artist.isEmpty { parts.append("artist:\"\(artist)\"") }
        if !album.isEmpty { parts.append("album:\"\(album)\"") }
        guard !parts.isEmpty else { return [] }
        var components = URLComponents(string: "https://api.deezer.com/search/album")!
        components.queryItems = [
            URLQueryItem(name: "q", value: parts.joined(separator: " ")),
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
        let root = try JSONDecoder().decode(DeezerResponse.self, from: data)
        return root.data.map { a in
            Album(
                id: a.id,
                artist: a.artist?.name ?? "",
                title: a.title ?? "",
                trackCount: a.nb_tracks,
                coverXL: a.cover_xl.flatMap(URL.init(string:)),
                coverBig: a.cover_big.flatMap(URL.init(string:))
            )
        }
    }
}

private struct DeezerResponse: Decodable {
    let data: [DeezerAlbum]
}

private struct DeezerAlbum: Decodable {
    let id: Int
    let title: String?
    let nb_tracks: Int?
    let cover_xl: String?
    let cover_big: String?
    let artist: DeezerArtist?
}

private struct DeezerArtist: Decodable {
    let name: String?
}
