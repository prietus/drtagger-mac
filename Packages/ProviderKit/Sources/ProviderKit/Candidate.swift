import Foundation

// Provider-agnostic representation of a release candidate. MusicBrainz and
// Discogs responses both get normalised into this shape so the UI and the
// identification scorer don't have to know which service a candidate came
// from. Codable so identification results persist with the album.

public struct Candidate: Sendable, Identifiable, Equatable, Codable, Hashable {
    public enum Source: String, Sendable, Equatable, Codable {
        case musicbrainz
        case discogs
        case acoustid
    }

    public let source: Source
    public let providerID: String       // stable ID on the source, e.g. MBID
    public let releaseGroupID: String?  // MB release-group MBID if known
    public let title: String
    public let artist: String
    public let year: String?            // just the year for display; full date lives in releasedDate
    public let country: String?
    public let label: String?
    public let catalogNumber: String?
    public let mediaFormat: String?     // "CD", "2×CD", "Vinyl", "Digital Media"
    public let trackCount: Int?         // total across media
    public let disambiguation: String?
    public let coverArtURL: URL?
    public let tracks: [CandidateTrack] // first medium (or all, for single-medium releases)

    // Extra release-level fields. These come mostly from Discogs (genres,
    // styles, full release date, format descriptions); MusicBrainz fills
    // them when it can. All optional so the merger only writes what the
    // candidate actually carries.
    public let releasedDate: String?         // full date "YYYY-MM-DD" if known
    public let genres: [String]              // e.g. ["Jazz"]
    public let styles: [String]              // e.g. ["Hard Bop", "Cool Jazz"]
    public let formatDescriptions: [String]  // e.g. ["Album", "Reissue", "SHM-CD"]

    // Identification fields (phase 4).
    public let barcode: String?
    public let media: [CandidateMedium]      // every medium with its tracks and disc IDs
    public let status: String?               // "Official", "Bootleg", …
    public let primaryType: String?          // "Album", "Single", …

    public var id: String { source.rawValue + ":" + providerID }

    public init(
        source: Source,
        providerID: String,
        releaseGroupID: String? = nil,
        title: String,
        artist: String,
        year: String? = nil,
        country: String? = nil,
        label: String? = nil,
        catalogNumber: String? = nil,
        mediaFormat: String? = nil,
        trackCount: Int? = nil,
        disambiguation: String? = nil,
        coverArtURL: URL? = nil,
        tracks: [CandidateTrack] = [],
        releasedDate: String? = nil,
        genres: [String] = [],
        styles: [String] = [],
        formatDescriptions: [String] = [],
        barcode: String? = nil,
        media: [CandidateMedium] = [],
        status: String? = nil,
        primaryType: String? = nil
    ) {
        self.source = source
        self.providerID = providerID
        self.releaseGroupID = releaseGroupID
        self.title = title
        self.artist = artist
        self.year = year
        self.country = country
        self.label = label
        self.catalogNumber = catalogNumber
        self.mediaFormat = mediaFormat
        self.trackCount = trackCount
        self.disambiguation = disambiguation
        self.coverArtURL = coverArtURL
        self.tracks = tracks
        self.releasedDate = releasedDate
        self.genres = genres
        self.styles = styles
        self.formatDescriptions = formatDescriptions
        self.barcode = barcode
        self.media = media
        self.status = status
        self.primaryType = primaryType
    }

    // Tracks of every medium in order; falls back to `tracks`.
    public var allTracks: [CandidateTrack] {
        media.isEmpty ? tracks : media.flatMap(\.tracks)
    }

    public var mediumCount: Int { max(1, media.count) }

    // Track counts a local rip could plausibly have: the total, or a single
    // layer of a hybrid disc.
    public var plausibleTrackCounts: Set<Int> {
        var set = Set<Int>()
        if let t = trackCount { set.insert(t) }
        let layers = media.filter(\.isLayer)
        if !layers.isEmpty {
            for m in layers { if let c = m.trackCount { set.insert(c) } }
            let others = media.filter { !$0.isLayer }.compactMap(\.trackCount).reduce(0, +)
            for m in layers { if let c = m.trackCount { set.insert(c + others) } }
        }
        return set
    }

    public var allDiscIDs: Set<String> { Set(media.flatMap(\.discIDs)) }

    // Catalog numbers as MB stores them, split on the joiner used when
    // several labels are credited.
    public var catalogNumbers: [String] {
        (catalogNumber ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

public struct CandidateMedium: Sendable, Equatable, Codable, Hashable {
    public let position: Int
    public let format: String?
    public let title: String?
    public let tracks: [CandidateTrack]
    public let discIDs: [String]
    public let trackCount: Int?          // known even when `tracks` is empty (search results)

    public init(position: Int, format: String? = nil, title: String? = nil, tracks: [CandidateTrack] = [], discIDs: [String] = [], trackCount: Int? = nil) {
        self.position = position
        self.format = format
        self.title = title
        self.tracks = tracks
        self.discIDs = discIDs
        self.trackCount = trackCount ?? (tracks.isEmpty ? nil : tracks.count)
    }

    public var isLayer: Bool { (format ?? "").lowercased().contains("layer") }
}

public struct CandidateTrack: Sendable, Equatable, Codable, Hashable {
    public let position: Int            // 1-based track number within its medium
    public let title: String
    public let artist: String?          // only set if different from release artist
    public let durationMS: Int?         // milliseconds
    public let credits: [TrackCredit]   // per-track credits (composers, sidemen, etc.)
    public let recordingID: String?     // MB recording MBID
    public let trackID: String?         // MB track MBID (release-specific)

    public init(
        position: Int,
        title: String,
        artist: String? = nil,
        durationMS: Int? = nil,
        credits: [TrackCredit] = [],
        recordingID: String? = nil,
        trackID: String? = nil
    ) {
        self.position = position
        self.title = title
        self.artist = artist
        self.durationMS = durationMS
        self.credits = credits
        self.recordingID = recordingID
        self.trackID = trackID
    }
}

// One per-track credit line. `role` is the raw provider string ("Written-By",
// "Bass", "Piano", "Producer", …) and `name` is the artist. The merger
// decides which roles map to which Vorbis tags.
public struct TrackCredit: Sendable, Equatable, Codable, Hashable {
    public let role: String
    public let name: String

    public init(role: String, name: String) {
        self.role = role
        self.name = name
    }
}
