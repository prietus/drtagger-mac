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
        let query = Self.catalogQuery(trimmed)

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

    // Exact lookup by EAN-13 / UPC barcode. Leading zeros differ between
    // UPC-A and EAN-13 spellings, so both forms are tried.
    public func searchByBarcode(_ barcode: String, limit: Int = 10) async throws -> [Candidate] {
        let digits = barcode.filter(\.isNumber)
        guard digits.count >= 8 else { return [] }
        var forms = [digits]
        if digits.count == 12 { forms.append("0" + digits) }
        if digits.count == 13, digits.hasPrefix("0") { forms.append(String(digits.dropFirst())) }
        let query = forms.map { "barcode:\($0)" }.joined(separator: " OR ")

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

    // Releases containing a CD with this Disc ID. When the ID is unknown
    // and `toc` is given, MusicBrainz falls back to a fuzzy TOC match
    // (same track offsets within a small tolerance). Returns [] on 404.
    public func lookupDiscID(_ discID: String, toc: String? = nil) async throws -> [Candidate] {
        var components = URLComponents(url: baseURL.appendingPathComponent("discid/\(discID)"), resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "inc", value: "recordings+artist-credits+labels+release-groups"),
            URLQueryItem(name: "cdstubs", value: "no"),
        ]
        // MusicBrainz wants "first+last+leadout+offsets…" with plus signs.
        if let toc { items.append(URLQueryItem(name: "toc", value: toc.replacingOccurrences(of: " ", with: "+"))) }
        components.queryItems = items
        guard let url = components.url else { throw ProviderError.invalidURL }
        let data: Data
        do {
            data = try await sendRateLimited(url: url)
        } catch ProviderError.httpError(404) {
            return []
        }
        let response = try JSONDecoder().decode(MBDiscResponse.self, from: data)
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
            URLQueryItem(name: "inc", value: "recordings+artist-credits+labels+media+release-groups+discids"),
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

        // MusicBrainz answers 503 ("server busy") under load; back off and
        // retry a couple of times before giving up.
        var attempt = 0
        while true {
            let (data, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
                if (http.statusCode == 503 || http.statusCode == 429) && attempt < 2 {
                    attempt += 1
                    try await Task.sleep(nanoseconds: UInt64(1.5 * Double(attempt) * 1_000_000_000))
                    nextAllowedRequest = Date().addingTimeInterval(1.05)
                    continue
                }
                throw ProviderError.httpError(http.statusCode)
            }
            return data
        }
    }

    private nonisolated func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "\\\"")
    }

    // Labels print catalog numbers one way and MusicBrainz editors enter
    // them another ("CAPP139 SA" vs "CAPP 139 SA" vs "CAPP-139-SA"), so the
    // query ORs the exact spellings with a prefix wildcard on the glued
    // letters+digits head.
    nonisolated static func catalogQuery(_ raw: String) -> String {
        let alnum = raw.uppercased().filter { $0.isLetter || $0.isNumber }
        var variants: [String] = [raw]
        // Split letters / digits boundaries with spaces and with hyphens.
        var spaced = ""
        var previous: Character? = nil
        for ch in alnum {
            if let p = previous, p.isLetter != ch.isLetter { spaced.append(" ") }
            spaced.append(ch)
            previous = ch
        }
        variants.append(spaced)
        variants.append(spaced.replacingOccurrences(of: " ", with: "-"))
        variants.append(alnum)
        var seen = Set<String>()
        var terms = variants.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .map { "catno:\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }
        // Prefix wildcard: letters plus the first digit run ("CAPP139*").
        if let m = alnum.firstMatch(of: #/^([A-Z]{2,10}[0-9]{2,7})/#) {
            terms.append("catno:\(m.1)*")
        }
        return terms.joined(separator: " OR ")
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

        let mediaList: [CandidateMedium] = (release.media ?? []).enumerated().map { mIdx, m in
            let tracks: [CandidateTrack] = (m.tracks ?? []).enumerated().map { idx, t in
                let credit = t.artistCredit?.map { $0.name ?? $0.artist?.name ?? "" }.filter { !$0.isEmpty }.joined(separator: ", ")
                return CandidateTrack(
                    position: Int(t.number ?? "\(idx + 1)") ?? (t.position ?? idx + 1),
                    title: t.title ?? t.recording?.title ?? "",
                    artist: (credit?.isEmpty == false && credit != artist) ? credit : nil,
                    durationMS: t.length ?? t.recording?.length,
                    recordingID: t.recording?.id,
                    trackID: t.id
                )
            }
            return CandidateMedium(
                position: m.position ?? mIdx + 1,
                format: m.format,
                title: m.title,
                tracks: tracks,
                discIDs: (m.discs ?? []).compactMap(\.id),
                trackCount: m.trackCount
            )
        }
        let firstMedium = release.media?.first
        let formats = mediaList.compactMap(\.format)
        let mediaFormat: String? = {
            guard let f = formats.first else { return firstMedium?.format }
            let count = mediaList.count
            if count > 1 && formats.allSatisfy({ $0 == f }) { return "\(count)×\(f)" }
            // Layers of one disc: "Hybrid SACD (CD layer)" + "Hybrid SACD (SACD layer…)" → "Hybrid SACD".
            let heads = Set(formats.map { $0.components(separatedBy: " (").first ?? $0 })
            if heads.count == 1, formats.contains(where: { $0.lowercased().contains("layer") }) { return heads.first }
            return f
        }()
        let trackCount = release.trackCount ?? (mediaList.isEmpty ? firstMedium?.trackCount : mediaList.reduce(0) { $0 + ($1.tracks.isEmpty ? 0 : $1.tracks.count) })
        let tracks: [CandidateTrack] = mediaList.first?.tracks ?? []

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
            tracks: tracks,
            releasedDate: (release.date?.count ?? 0) >= 10 ? release.date : nil,
            barcode: release.barcode.flatMap { $0.isEmpty ? nil : $0 },
            media: mediaList,
            status: release.status,
            primaryType: release.releaseGroup?.primaryType
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

private struct MBDiscResponse: Decodable {
    let releases: [MBRelease]
}

private struct MBRelease: Decodable {
    let id: String
    let title: String?
    let date: String?
    let country: String?
    let disambiguation: String?
    let barcode: String?
    let status: String?
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
        case id, title, date, country, disambiguation, barcode, status
        case trackCount = "track-count"
        case artistCredit = "artist-credit"
        case labelInfo = "label-info"
        case media
        case releaseGroup = "release-group"
    }
}

private struct MBReleaseGroup: Decodable {
    let id: String
    let primaryType: String?
    enum CodingKeys: String, CodingKey {
        case id
        case primaryType = "primary-type"
    }
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
    let position: Int?
    let format: String?
    let title: String?
    let trackCount: Int?
    let tracks: [MBTrack]?
    let discs: [MBDisc]?
    enum CodingKeys: String, CodingKey {
        case position, format, title, tracks, discs
        case trackCount = "track-count"
    }
}

private struct MBDisc: Decodable {
    let id: String?
}

private struct MBTrack: Decodable {
    let id: String?
    let number: String?
    let position: Int?
    let title: String?
    let length: Int?
    let recording: MBRecording?
    let artistCredit: [MBArtistCredit]?
    enum CodingKeys: String, CodingKey {
        case id, number, position, title, length, recording
        case artistCredit = "artist-credit"
    }
}

private struct MBRecording: Decodable {
    let id: String?
    let title: String?
    let length: Int?
}
