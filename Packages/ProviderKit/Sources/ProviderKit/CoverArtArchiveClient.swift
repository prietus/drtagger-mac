import Foundation

// Cover Art Archive (no key): the images attached to a MusicBrainz release.
// GET https://coverartarchive.org/release/<mbid> returns 404 when the
// release has no art, which is common and not an error.
public actor CoverArtArchiveClient {

    public struct Image: Sendable, Equatable, Codable, Hashable {
        public let id: String
        public let isFront: Bool
        public let isBack: Bool
        public let types: [String]
        public let fullURL: URL
        public let large: URL?      // 1200 px
        public let small: URL?      // 500 px
        public let thumbnail: URL?  // 250 px
        public let comment: String?
    }

    public let userAgent: String
    private let session: URLSession

    public init(userAgent: String, session: URLSession = .shared) {
        self.userAgent = userAgent
        self.session = session
    }

    public func images(releaseID: String) async throws -> [Image] {
        guard let url = URL(string: "https://coverartarchive.org/release/\(releaseID)") else { throw ProviderError.invalidURL }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse {
            if http.statusCode == 404 { return [] }
            if http.statusCode >= 400 { throw ProviderError.httpError(http.statusCode) }
        }
        return try Self.parse(data)
    }

    public nonisolated static func frontURL(releaseID: String, size: Int = 1200) -> URL {
        URL(string: "https://coverartarchive.org/release/\(releaseID)/front-\(size)")!
    }

    nonisolated static func parse(_ data: Data) throws -> [Image] {
        let root = try JSONDecoder().decode(CAAResponse.self, from: data)
        return root.images.compactMap { img in
            guard let full = URL(string: img.image) else { return nil }
            return Image(
                id: img.id.map(String.init) ?? "",
                isFront: img.front ?? false,
                isBack: img.back ?? false,
                types: img.types ?? [],
                fullURL: full,
                large: img.thumbnails?["1200"].flatMap(URL.init(string:)),
                small: img.thumbnails?["500"].flatMap(URL.init(string:)),
                thumbnail: img.thumbnails?["250"].flatMap(URL.init(string:)),
                comment: img.comment.flatMap { $0.isEmpty ? nil : $0 }
            )
        }
    }
}

private struct CAAResponse: Decodable {
    let images: [CAAImage]
}

private struct CAAImage: Decodable {
    let id: Int?
    let image: String
    let front: Bool?
    let back: Bool?
    let types: [String]?
    let comment: String?
    let thumbnails: [String: String]?
}
