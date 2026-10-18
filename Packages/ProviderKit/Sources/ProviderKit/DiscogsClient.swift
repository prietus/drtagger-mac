import Foundation

// Discogs HTTP client.
//
// API docs: https://www.discogs.com/developers/
// Auth: personal access token, sent as `Authorization: Discogs token=XYZ`.
// Rate limit: 60 requests/minute for authenticated calls. We serialise
// through the actor with a 1.05s spacing, same shape as MusicBrainzClient,
// so two heavy parallel callers can't burst us past the line.

public actor DiscogsClient {

    public let userAgent: String
    public let token: String
    private let session: URLSession
    private let baseURL = URL(string: "https://api.discogs.com/")!
    private var nextAllowedRequest: Date = .distantPast

    public init(userAgent: String, token: String, session: URLSession = .shared) {
        self.userAgent = userAgent
        self.token = token
        self.session = session
    }

    public var isConfigured: Bool { !token.isEmpty }

    // MARK: Search

    public func searchReleases(artist: String, album: String, format: String? = nil, limit: Int = 25) async throws -> [Candidate] {
        let trimmedArtist = artist.trimmingCharacters(in: .whitespaces)
        let trimmedAlbum = album.trimmingCharacters(in: .whitespaces)
        guard !trimmedArtist.isEmpty || !trimmedAlbum.isEmpty else { return [] }

        var components = URLComponents(url: baseURL.appendingPathComponent("database/search"), resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "type", value: "release"),
            URLQueryItem(name: "per_page", value: String(limit)),
        ]
        if !trimmedArtist.isEmpty {
            items.append(URLQueryItem(name: "artist", value: trimmedArtist))
        }
        if !trimmedAlbum.isEmpty {
            items.append(URLQueryItem(name: "release_title", value: trimmedAlbum))
        }
        if let format {
            items.append(URLQueryItem(name: "format", value: format))
        }
        components.queryItems = items
        guard let url = components.url else { return [] }

        let data = try await sendRateLimited(url: url)
        let response = try JSONDecoder().decode(DiscogsSearchResponse.self, from: data)
        return response.results.map { Self.toCandidate(searchHit: $0) }
    }

    // Lookup by EAN-13/UPC. Discogs indexes the barcode field directly so
    // a hit here is effectively a 100% match for that pressing — exactly
    // what we want when the user has scanned the back-cover barcode.
    public func searchByBarcode(_ barcode: String, limit: Int = 10) async throws -> [Candidate] {
        let trimmed = barcode.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        var components = URLComponents(url: baseURL.appendingPathComponent("database/search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "type", value: "release"),
            URLQueryItem(name: "barcode", value: trimmed),
            URLQueryItem(name: "per_page", value: String(limit)),
        ]
        guard let url = components.url else { return [] }

        let data = try await sendRateLimited(url: url)
        let response = try JSONDecoder().decode(DiscogsSearchResponse.self, from: data)
        return response.results.map { Self.toCandidate(searchHit: $0) }
    }

    public func searchByCatalog(_ catalogNumber: String, limit: Int = 10) async throws -> [Candidate] {
        let trimmed = catalogNumber.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        var components = URLComponents(url: baseURL.appendingPathComponent("database/search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "type", value: "release"),
            URLQueryItem(name: "catno", value: trimmed),
            URLQueryItem(name: "per_page", value: String(limit)),
        ]
        guard let url = components.url else { return [] }

        let data = try await sendRateLimited(url: url)
        let response = try JSONDecoder().decode(DiscogsSearchResponse.self, from: data)
        return response.results.map { Self.toCandidate(searchHit: $0) }
    }

    // Fetch full release detail (tracklist) for a Discogs release ID. The
    // search endpoint doesn't return tracks, so this is required before we
    // can build a per-track diff.
    public func releaseDetail(id: String) async throws -> Candidate {
        let url = baseURL.appendingPathComponent("releases/\(id)")
        return try Self.decodeRelease(try await sendRateLimited(url: url))
    }

    static func decodeRelease(_ data: Data) throws -> Candidate {
        Self.toCandidate(release: try JSONDecoder().decode(DiscogsRelease.self, from: data))
    }

    // Every photo on a Discogs release page, primary first. Discogs does not
    // say which one is the obi or the back: users upload them as they like.
    public struct ReleaseImage: Sendable, Equatable, Hashable, Codable {
        public let url: URL
        public let thumbnail: URL?
        public let isPrimary: Bool
        public let width: Int?
        public let height: Int?
    }

    public func images(releaseID id: String) async throws -> [ReleaseImage] {
        let data = try await sendRateLimited(url: baseURL.appendingPathComponent("releases/\(id)"))
        return Self.parseImages(data)
    }

    static func parseImages(_ data: Data) -> [ReleaseImage] {
        let images = (try? JSONDecoder().decode(DiscogsImagesOnly.self, from: data))?.images ?? []
        let mapped = images.compactMap { i -> ReleaseImage? in
            guard let u = i.uri.flatMap(URL.init(string:)) else { return nil }
            return ReleaseImage(url: u, thumbnail: i.uri150.flatMap(URL.init(string:)), isPrimary: i.type == "primary", width: i.width, height: i.height)
        }
        return mapped.filter(\.isPrimary) + mapped.filter { !$0.isPrimary }
    }

    // MARK: Rate-limited HTTP

    private func sendRateLimited(url: URL) async throws -> Data {
        // Reserve a slot before waiting: concurrent callers (the actor is
        // re-entered while one sleeps) each get their own, 1.05 s apart.
        let slot = max(Date(), nextAllowedRequest)
        nextAllowedRequest = slot.addingTimeInterval(1.05)
        let wait = slot.timeIntervalSinceNow
        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }

        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if !token.isEmpty {
            req.setValue("Discogs token=\(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            throw ProviderError.httpError(http.statusCode)
        }
        return data
    }

    // MARK: Mapping

    // Map a search-result hit (lighter, no tracklist) to a Candidate.
    // Discogs search returns "title" already in "Artist - Album" form.
    private static func toCandidate(searchHit hit: DiscogsSearchHit) -> Candidate {
        let (artist, album) = splitTitle(hit.title)
        let label = hit.label?.first
        let catNo = hit.catno
        let format = hit.format?.first
        let country = hit.country
        let year = hit.year.flatMap { $0.isEmpty ? nil : $0 }

        // Discogs returns a transparent "spacer.gif" placeholder instead
        // of null when a release has no artwork. Treat it as absent so
        // the UI shows our own placeholder rather than a blank image.
        let cover = hit.coverImage
            .flatMap { Self.isRealCoverURL($0) ? $0 : nil }
            .flatMap(URL.init(string:))

        return Candidate(
            source: .discogs,
            providerID: String(hit.id),
            title: album,
            artist: artist,
            year: year,
            country: country,
            label: label,
            catalogNumber: catNo,
            mediaFormat: format,
            trackCount: nil,
            disambiguation: nil,
            coverArtURL: cover,
            tracks: [],
            releasedDate: nil,
            genres: hit.genre ?? [],
            styles: hit.style ?? [],
            formatDescriptions: []
        )
    }

    // Map a full release fetch to a Candidate. Includes tracks.
    private static func toCandidate(release r: DiscogsRelease) -> Candidate {
        let artist = (r.artists ?? [])
            .map { $0.name ?? "" }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")

        let labelInfo = r.labels?.first
        let label = labelInfo?.name
        // Every label's catalog number, like MusicBrainz candidates carry them.
        let catalogs = (r.labels ?? []).compactMap { $0.catno }.filter { !$0.isEmpty && $0.lowercased() != "none" }
        let catNo = catalogs.isEmpty ? labelInfo?.catno : Array(NSOrderedSet(array: catalogs)).compactMap { $0 as? String }.joined(separator: ", ")
        // The barcode, digits only ("4 988031 573259" → "4988031573259").
        let barcode = (r.identifiers ?? []).filter { ($0.type ?? "").lowercased() == "barcode" }
            .compactMap { $0.value?.filter(\.isNumber) }
            .first { (8...14).contains($0.count) }
        let firstFormat = r.formats?.first
        let format = firstFormat?.name
        let formatDescriptions = firstFormat?.descriptions ?? []
        let year: String? = {
            if let y = r.year, y > 0 { return String(y) }
            if let date = r.released, !date.isEmpty { return String(date.prefix(4)) }
            return nil
        }()
        let releasedDate: String? = {
            guard let date = r.released, !date.isEmpty else { return nil }
            return date
        }()

        let primaryURI = r.images?.first(where: { $0.type == "primary" })?.uri
        let firstURI = r.images?.first?.uri
        let cover = [primaryURI, firstURI]
            .compactMap { $0 }
            .first(where: { Self.isRealCoverURL($0) })
            .flatMap(URL.init(string:))

        // CD+DVD editions: the DVD's tracks ("DVD-1"…) are video, unless it is a DVD-Audio.
        let formats = r.formats ?? []
        let videoDVD = formats.count > 1 && formats.contains { $0.name == "DVD" && !($0.descriptions ?? []).contains("DVD-Audio") }
            && formats.contains { $0.name != "DVD" }
        let tracks: [CandidateTrack] = (r.tracklist ?? [])
            .filter { ($0.type_ ?? "track") == "track" }
            .filter { !videoDVD || !($0.position ?? "").uppercased().hasPrefix("DVD") }
            .enumerated()
            .map { idx, t in
                let credits: [TrackCredit] = (t.extraartists ?? []).compactMap {
                    guard let name = $0.name, !name.isEmpty else { return nil }
                    return TrackCredit(role: $0.role ?? "", name: name)
                }
                return CandidateTrack(
                    position: parsePosition(t.position) ?? (idx + 1),
                    title: t.title ?? "",
                    artist: nil,
                    durationMS: parseDurationMS(t.duration),
                    credits: credits
                )
            }

        return Candidate(
            source: .discogs,
            providerID: String(r.id),
            title: r.title ?? "",
            artist: artist,
            year: year,
            country: r.country,
            label: label,
            catalogNumber: catNo,
            mediaFormat: format,
            trackCount: tracks.isEmpty ? nil : tracks.count,
            disambiguation: nil,
            coverArtURL: cover,
            tracks: tracks,
            releasedDate: releasedDate,
            genres: r.genres ?? [],
            styles: r.styles ?? [],
            formatDescriptions: formatDescriptions,
            barcode: barcode,
            media: tracks.isEmpty ? [] : [CandidateMedium(position: 1, format: format, tracks: tracks)]
        )
    }

    // Discogs has a couple of well-known placeholder assets that show up
    // in the `cover_image`/`uri` fields for releases without art. We
    // reject them so the UI falls through to our own placeholder
    // instead of trying (and failing) to decode a spacer gif.
    private static func isRealCoverURL(_ s: String) -> Bool {
        let lower = s.lowercased()
        if lower.isEmpty { return false }
        if lower.contains("spacer.gif") { return false }
        if lower.contains("/spacer") { return false }
        return true
    }

    private static func splitTitle(_ raw: String) -> (artist: String, album: String) {
        if let range = raw.range(of: " - ") {
            return (String(raw[..<range.lowerBound]), String(raw[range.upperBound...]))
        }
        return ("", raw)
    }

    // Discogs uses "1", "A1", "1.1" etc. We just want a 1-based integer for
    // matching against local track ordering, so strip the side prefix and
    // grab the trailing number.
    private static func parsePosition(_ s: String?) -> Int? {
        guard let s, !s.isEmpty else { return nil }
        let digits = s.reversed().prefix { $0.isNumber }.reversed()
        return Int(String(digits))
    }

    private static func parseDurationMS(_ s: String?) -> Int? {
        guard let s, !s.isEmpty else { return nil }
        let parts = s.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 2: return (parts[0] * 60 + parts[1]) * 1000
        case 3: return (parts[0] * 3600 + parts[1] * 60 + parts[2]) * 1000
        default: return nil
        }
    }
}

// MARK: - Decodable wire types

private struct DiscogsSearchResponse: Decodable {
    let results: [DiscogsSearchHit]
}

private struct DiscogsSearchHit: Decodable {
    let id: Int
    let title: String          // "Artist - Album"
    let year: String?
    let country: String?
    let label: [String]?
    let catno: String?
    let format: [String]?
    let coverImage: String?
    let thumb: String?
    let genre: [String]?
    let style: [String]?

    enum CodingKeys: String, CodingKey {
        case id, title, year, country, label, catno, format, thumb, genre, style
        case coverImage = "cover_image"
    }
}

private struct DiscogsRelease: Decodable {
    let id: Int
    let title: String?
    let year: Int?
    let released: String?
    let country: String?
    let genres: [String]?
    let styles: [String]?
    let artists: [DiscogsArtist]?
    let labels: [DiscogsLabel]?
    let formats: [DiscogsFormat]?
    let images: [DiscogsImage]?
    let tracklist: [DiscogsTrack]?
    let identifiers: [DiscogsIdentifier]?
}

private struct DiscogsIdentifier: Decodable {
    let type: String?
    let value: String?
}

private struct DiscogsArtist: Decodable {
    let name: String?
}

private struct DiscogsLabel: Decodable {
    let name: String?
    let catno: String?
}

private struct DiscogsFormat: Decodable {
    let name: String?
    let descriptions: [String]?
}

private struct DiscogsImage: Decodable {
    let type: String?
    let uri: String?
    let uri150: String?
    let width: Int?
    let height: Int?
}

private struct DiscogsImagesOnly: Decodable {
    let images: [DiscogsImage]?
}

private struct DiscogsTrack: Decodable {
    let position: String?
    let title: String?
    let duration: String?
    let type_: String?
    let extraartists: [DiscogsExtraArtist]?
    enum CodingKeys: String, CodingKey {
        case position, title, duration, extraartists
        case type_ = "type_"
    }
}

private struct DiscogsExtraArtist: Decodable {
    let name: String?
    let role: String?
}
