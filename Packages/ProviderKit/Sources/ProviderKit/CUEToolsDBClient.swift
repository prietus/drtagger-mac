import Foundation

// CUETools Database (db.cuetools.net): a public, key-less database of CD
// rip checksums. One TOC lookup returns every known rip of that disc with
// per-track CRC32s, plus MusicBrainz / FreeDB metadata candidates for the
// same TOC. Verified format on 2026-09-20 against two real rips:
//
//   track CRC = CRC32 of the track's 16-bit PCM, where the first 5880
//   samples after track 1's INDEX 01 and the last 5880 samples of the disc
//   are excluded ("stride" 5880). The disc CRC covers the same range.
//
// Endpoint: GET http://db.cuetools.net/lookup2.php?version=3&ctdb=1
//           &metadata=fast&fuzzy=1&toc=<start1:start2:…:leadout>
public actor CUEToolsDBClient {

    public static let strideSamples = 5880

    public struct Entry: Sendable, Equatable, Hashable, Codable {
        public let id: String
        public let confidence: Int
        public let discCRC32: UInt32
        public let trackCRC32s: [UInt32]
        public let toc: String
        public let hasParity: Bool

        public init(id: String, confidence: Int, discCRC32: UInt32, trackCRC32s: [UInt32], toc: String, hasParity: Bool) {
            self.id = id
            self.confidence = confidence
            self.discCRC32 = discCRC32
            self.trackCRC32s = trackCRC32s
            self.toc = toc
            self.hasParity = hasParity
        }
    }

    public struct MetadataTrack: Sendable, Equatable, Hashable, Codable {
        public let name: String
        public let artist: String?
    }

    public struct Metadata: Sendable, Equatable, Hashable, Codable {
        public let source: String          // "musicbrainz", "freedb", …
        public let id: String?             // MusicBrainz release MBID when source is musicbrainz
        public let album: String
        public let artist: String
        public let year: String?
        public let barcode: String?
        public let label: String?
        public let catalogNumber: String?
        public let country: String?
        public let releaseDate: String?
        public let discNumber: Int?
        public let discCount: Int?
        public let relevance: Int
        public let tracks: [MetadataTrack]
    }

    public struct Response: Sendable, Equatable, Codable {
        public let entries: [Entry]
        public let metadata: [Metadata]

        public var totalConfidence: Int { entries.reduce(0) { $0 + $1.confidence } }
        public var bestEntry: Entry? { entries.max { $0.confidence < $1.confidence } }
    }

    public enum CTDBError: LocalizedError, Equatable {
        case invalidResponse

        public var errorDescription: String? {
            "CUETools DB returned an unexpected response."
        }
    }

    public let userAgent: String
    private let session: URLSession
    private let baseURL = URL(string: "http://db.cuetools.net/lookup2.php")!

    public init(userAgent: String, session: URLSession = .shared) {
        self.userAgent = userAgent
        self.session = session
    }

    // `toc` is DiscTOC.ctdbTOCString: relative frame offsets and lead-out.
    public func lookup(toc: String) async throws -> Response {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "version", value: "3"),
            URLQueryItem(name: "ctdb", value: "1"),
            URLQueryItem(name: "metadata", value: "fast"),
            URLQueryItem(name: "fuzzy", value: "1"),
            URLQueryItem(name: "toc", value: toc),
        ]
        guard let url = components.url else { throw ProviderError.invalidURL }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            throw ProviderError.httpError(http.statusCode)
        }
        return try Self.parse(data)
    }

    // MARK: - Verification

    public struct TrackVerdict: Sendable, Equatable, Codable {
        public let trackIndex: Int          // 0-based position in the TOC
        public let matchedConfidence: Int   // sum of confidence of entries whose CRC matches
        public let bestEntryMatches: Bool
    }

    public struct Verification: Sendable, Equatable, Codable {
        public let tracks: [TrackVerdict]
        public let discMatchesBestEntry: Bool
        public let totalConfidence: Int

        public var matchedTrackCount: Int { tracks.filter { $0.matchedConfidence > 0 }.count }
        public var allTracksMatch: Bool { !tracks.isEmpty && tracks.allSatisfy { $0.matchedConfidence > 0 } }
    }

    // Compares CRCs computed with the CTDB stride rule against every entry.
    public nonisolated static func verify(trackCRC32s: [UInt32], discCRC32: UInt32?, response: Response) -> Verification {
        let best = response.bestEntry
        var verdicts: [TrackVerdict] = []
        for (i, crc) in trackCRC32s.enumerated() {
            var confidence = 0
            for entry in response.entries where i < entry.trackCRC32s.count && entry.trackCRC32s[i] == crc {
                confidence += entry.confidence
            }
            let bestMatches = best.map { i < $0.trackCRC32s.count && $0.trackCRC32s[i] == crc } ?? false
            verdicts.append(TrackVerdict(trackIndex: i, matchedConfidence: confidence, bestEntryMatches: bestMatches))
        }
        let discMatches = (best != nil && discCRC32 != nil) ? best!.discCRC32 == discCRC32! : false
        return Verification(tracks: verdicts, discMatchesBestEntry: discMatches, totalConfidence: response.totalConfidence)
    }

    // MARK: - XML parsing

    public nonisolated static func parse(_ data: Data) throws -> Response {
        let delegate = CTDBParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), delegate.sawRoot else { throw CTDBError.invalidResponse }
        return Response(entries: delegate.entries, metadata: delegate.metadata)
    }
}

private final class CTDBParserDelegate: NSObject, XMLParserDelegate {
    var sawRoot = false
    var entries: [CUEToolsDBClient.Entry] = []
    var metadata: [CUEToolsDBClient.Metadata] = []

    private var current: [String: String]? = nil
    private var currentTracks: [CUEToolsDBClient.MetadataTrack] = []
    private var currentLabel: (name: String?, catno: String?) = (nil, nil)
    private var currentRelease: (country: String?, date: String?) = (nil, nil)

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes attrs: [String: String]) {
        switch name {
        case "ctdb":
            sawRoot = true
        case "entry":
            let crcs = (attrs["trackcrcs"] ?? "")
                .split(separator: " ")
                .compactMap { UInt32($0, radix: 16) }
            entries.append(CUEToolsDBClient.Entry(
                id: attrs["id"] ?? "",
                confidence: Int(attrs["confidence"] ?? "") ?? 0,
                discCRC32: UInt32(attrs["crc32"] ?? "", radix: 16) ?? 0,
                trackCRC32s: crcs,
                toc: attrs["toc"] ?? "",
                hasParity: attrs["hasparity"] != nil
            ))
        case "metadata":
            current = attrs
            currentTracks = []
            currentLabel = (nil, nil)
            currentRelease = (nil, nil)
        case "track" where current != nil:
            currentTracks.append(CUEToolsDBClient.MetadataTrack(name: attrs["name"] ?? "", artist: attrs["artist"]))
        case "label" where current != nil:
            currentLabel = (attrs["name"], attrs["catno"])
        case "release" where current != nil:
            currentRelease = (attrs["country"], attrs["date"])
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard name == "metadata", let attrs = current else { return }
        metadata.append(CUEToolsDBClient.Metadata(
            source: attrs["source"] ?? "",
            id: attrs["id"],
            album: attrs["album"] ?? "",
            artist: attrs["artist"] ?? "",
            year: attrs["year"],
            barcode: attrs["barcode"].flatMap { $0.isEmpty ? nil : $0 },
            label: currentLabel.name,
            catalogNumber: currentLabel.catno,
            country: currentRelease.country,
            releaseDate: currentRelease.date,
            discNumber: Int(attrs["discnumber"] ?? ""),
            discCount: Int(attrs["disccount"] ?? ""),
            relevance: Int(attrs["relevance"] ?? "") ?? 0,
            tracks: currentTracks
        ))
        current = nil
    }
}
