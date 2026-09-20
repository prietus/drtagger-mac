import Foundation

// MusicBrainz HTTP client.
//
// API docs: https://musicbrainz.org/doc/MusicBrainz_API
// Rules the server strictly enforces:
//   - Every request must carry a descriptive User-Agent. Anonymous UAs get
//     403'd. Format: "app/version ( contact )".
//   - Anonymous rate limit: 1 request per second per IP (burst is
//     tolerated but bursts over 50 get you banned). We serialise through
//     the actor + asleep() to stay below the line.
//   - fmt=json is required unless you like XML.

public actor MusicBrainzClient {

    public let userAgent: String
    private let session: URLSession
    private let baseURL = URL(string: "https://musicbrainz.org/ws/2/")!
    private var nextAllowedRequest: Date = .distantPast

    public init(userAgent: String, session: URLSession = .shared) {
        self.userAgent = userAgent
        self.session = session
    }

    // Targeted search by catalog number. MusicBrainz's Lucene `catno` field
    // lets us jump directly to a specific pressing when the caller already
    // knows its catalog code, bypassing the noisy relevance ranking of the
    // plain artist+release search. Returns the matching releases in the
    // same Candidate shape as searchReleases().
    public func searchByCatalog(_ catalogNumber: String, limit: Int = 10) async throws -> [Candidate] {
        let trimmed = catalogNumber.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let query = "catno:\"\(escape(trimmed))\""

        var components = URLComponents(url: baseURL.appendingPathComponent("release"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        guard let url = components.url else { return [] }

        let data = try await sendRateLimited(url: url)
        let response = try JSONDecoder().decode(MBReleaseSearchResponse.self, from: data)
        return response.releases.map { Self.toCandidate($0, disambiguationFallback: nil) }
    }

    // MARK: Search

    public func searchReleases(artist: String, album: String, limit: Int = 10) async throws -> [Candidate] {
        let trimmedArtist = artist.trimmingCharacters(in: .whitespaces)
        let trimmedAlbum = album.trimmingCharacters(in: .whitespaces)
        guard !trimmedArtist.isEmpty || !trimmedAlbum.isEmpty else { return [] }

        // Lucene query: quoted terms + AND. Escaping colons etc. isn't
        // strictly needed for simple titles; if we hit weird inputs we'll
        // revisit.
        var parts: [String] = []
        if !trimmedArtist.isEmpty {
            parts.append("artist:\"\(escape(trimmedArtist))\"")
        }
        if !trimmedAlbum.isEmpty {
            parts.append("release:\"\(escape(trimmedAlbum))\"")
        }
        let query = parts.joined(separator: " AND ")

        var components = URLComponents(url: baseURL.appendingPathComponent("release"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        guard let url = components.url else { return [] }

        let data = try await sendRateLimited(url: url)
        let response = try JSONDecoder().decode(MBReleaseSearchResponse.self, from: data)
        return response.releases.map { Self.toCandidate($0, disambiguationFallback: nil) }
    }

    // Fetch full tracklist + credits for a specific release MBID.
    public func releaseDetail(id mbid: String) async throws -> Candidate {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("release/\(mbid)"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "inc", value: "recordings+artist-credits+labels+media+release-groups"),
        ]
        guard let url = components.url else {
            throw ProviderError.invalidURL
        }

        let data = try await sendRateLimited(url: url)
        let release = try JSONDecoder().decode(MBRelease.self, from: data)
        return Self.toCandidate(release, disambiguationFallback: nil)
    }

    // Browse every release in a release-group. Used to expand a single
    // AcoustID fingerprint hit into every known edition (CD, SACD, vinyl,
    // reissues, country variants) of the same album. The browse endpoint
    // is paginated at 100 which is plenty for any real album.
    public func releasesInGroup(id releaseGroupID: String, limit: Int = 100) async throws -> [Candidate] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("release"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "release-group", value: releaseGroupID),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "inc", value: "artist-credits+labels+media"),
        ]
        guard let url = components.url else { return [] }

        let data = try await sendRateLimited(url: url)
        let response = try JSONDecoder().decode(MBReleaseBrowseResponse.self, from: data)
        return response.releases.map {
            var release = $0
            release.releaseGroupID = releaseGroupID
            return Self.toCandidate(release, disambiguationFallback: nil)
        }
    }

    // MARK: Rate-limited HTTP

    private func sendRateLimited(url: URL) async throws -> Data {
        let now = Date()
        if now < nextAllowedRequest {
            let wait = nextAllowedRequest.timeIntervalSince(now)
            try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
        // Schedule the next slot before the request so concurrent callers
        // queue up correctly.
        nextAllowedRequest = Date().addingTimeInterval(1.05)

        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            throw ProviderError.httpError(http.statusCode)
        }
        return data
    }

    private nonisolated func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: JSON → Candidate mapping

    private static func toCandidate(_ release: MBRelease, disambiguationFallback: String?) -> Candidate {
        let artist = release.artistCredit?
            .map { $0.name ?? $0.artist?.name ?? "" }
            .filter { !$0.isEmpty }
            .joined(separator: ", ") ?? ""

        let year: String? = {
            guard let date = release.date, !date.isEmpty else { return nil }
            return String(date.prefix(4))
        }()

        // Reissues are often co-credited: e.g. "Analogue Productions, Geffen
        // Records" with their own catalog numbers. Picking just the first
        // label hides the reissue publisher (often the interesting one for
        // audiophile pressings) behind the major. Join every distinct label
        // and catalog so the user sees what MB actually knows.
        let labelNames = (release.labelInfo ?? [])
            .compactMap { $0.label?.name }
            .filter { !$0.isEmpty }
        let label = labelNames.isEmpty
            ? nil
            : Array(NSOrderedSet(array: labelNames)).compactMap { $0 as? String }.joined(separator: ", ")
        let catalogNumbers = (release.labelInfo ?? [])
            .compactMap { $0.catalogNumber }
            .filter { !$0.isEmpty }
        let catalogNumber = catalogNumbers.isEmpty
            ? nil
            : Array(NSOrderedSet(array: catalogNumbers)).compactMap { $0 as? String }.joined(separator: ", ")

        let firstMedium = release.media?.first
        let mediaFormat = firstMedium?.format
        let trackCount = release.trackCount ?? firstMedium?.trackCount

        let tracks: [CandidateTrack] = (firstMedium?.tracks ?? []).enumerated().map { idx, t in
            CandidateTrack(
                position: Int(t.number ?? "\(idx + 1)") ?? (idx + 1),
                title: t.title ?? "",
                artist: nil,
                durationMS: t.length
            )
        }

        // Cover Art Archive serves per-release front covers at a predictable
        // URL. Many releases have no cover — in that case the URL 404s and
        // AsyncImage just shows the placeholder, so we can always produce
        // the URL without checking first.
        let coverURL = URL(string: "https://coverartarchive.org/release/\(release.id)/front-250")

        return Candidate(
            source: .musicbrainz,
            providerID: release.id,
            releaseGroupID: release.releaseGroupID ?? release.releaseGroup?.id,
            title: release.title ?? "",
            artist: artist,
            year: year,
            country: release.country,
            label: label,
            catalogNumber: catalogNumber,
            mediaFormat: mediaFormat,
            trackCount: trackCount,
            disambiguation: release.disambiguation ?? disambiguationFallback,
            coverArtURL: coverURL,
            tracks: tracks
        )
    }
}

// MARK: - Decodable wire types

private struct MBReleaseSearchResponse: Decodable {
    let releases: [MBRelease]
}

private struct MBReleaseBrowseResponse: Decodable {
    let releases: [MBRelease]
}

private struct MBRelease: Decodable {
    let id: String
    let title: String?
    let date: String?
    let country: String?
    let disambiguation: String?
    let trackCount: Int?
    let artistCredit: [MBArtistCredit]?
    let labelInfo: [MBLabelInfo]?
    let media: [MBMedium]?
    let releaseGroup: MBReleaseGroup?

    // Populated manually when we already know the group ID from the
    // browse query; otherwise derived from the `release-group` key that
    // comes back when `inc=release-groups` is present.
    var releaseGroupID: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, title, date, country, disambiguation
        case trackCount = "track-count"
        case artistCredit = "artist-credit"
        case labelInfo = "label-info"
        case media
        case releaseGroup = "release-group"
    }
}

private struct MBReleaseGroup: Decodable {
    let id: String
}

private struct MBArtistCredit: Decodable {
    let name: String?
    let artist: MBArtist?
}

private struct MBArtist: Decodable {
    let name: String?
}

private struct MBLabelInfo: Decodable {
    let catalogNumber: String?
    let label: MBLabel?
    enum CodingKeys: String, CodingKey {
        case catalogNumber = "catalog-number"
        case label
    }
}

private struct MBLabel: Decodable {
    let name: String?
}

private struct MBMedium: Decodable {
    let format: String?
    let trackCount: Int?
    let tracks: [MBTrack]?
    enum CodingKeys: String, CodingKey {
        case format
        case trackCount = "track-count"
        case tracks
    }
}

private struct MBTrack: Decodable {
    let number: String?
    let title: String?
    let length: Int?
}
