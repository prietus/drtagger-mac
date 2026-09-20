import Foundation

// Provider-agnostic representation of a release candidate. MusicBrainz and
// Discogs responses both get normalised into this shape so the UI doesn't
// have to know which service a candidate came from.

public struct Candidate: Sendable, Identifiable, Equatable {
    public enum Source: String, Sendable, Equatable {
        case musicbrainz
        case discogs
        case acoustid
    }

    public let source: Source
    public let providerID: String       // stable ID on the source, e.g. MBID
    public let releaseGroupID: String?  // MB release-group MBID if known
    public let title: String
    public let artist: String
    public let year: String?            // just the year for display; full date lives in rawDate
    public let country: String?
    public let label: String?
    public let catalogNumber: String?
    public let mediaFormat: String?     // "CD", "2×CD", "Vinyl", "Digital Media"
    public let trackCount: Int?
    public let disambiguation: String?
    public let coverArtURL: URL?
    public let tracks: [CandidateTrack]

    // Extra release-level fields. These come mostly from Discogs (genres,
    // styles, full release date, format descriptions); MusicBrainz fills
    // them when it can. All optional so the merger only writes what the
    // candidate actually carries.
    public let releasedDate: String?         // full date "YYYY-MM-DD" if known
    public let genres: [String]              // e.g. ["Jazz"]
    public let styles: [String]              // e.g. ["Hard Bop", "Cool Jazz"]
    public let formatDescriptions: [String]  // e.g. ["Album", "Reissue", "SHM-CD"]

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
        formatDescriptions: [String] = []
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
    }
}

public struct CandidateTrack: Sendable, Equatable {
    public let position: Int            // 1-based track number
    public let title: String
    public let artist: String?          // only set if different from release artist
    public let durationMS: Int?         // milliseconds
    public let credits: [TrackCredit]   // per-track credits (composers, sidemen, etc.)

    public init(
        position: Int,
        title: String,
        artist: String? = nil,
        durationMS: Int? = nil,
        credits: [TrackCredit] = []
    ) {
        self.position = position
        self.title = title
        self.artist = artist
        self.durationMS = durationMS
        self.credits = credits
    }
}

// One per-track credit line. `role` is the raw provider string ("Written-By",
// "Bass", "Piano", "Producer", …) and `name` is the artist. The merger
// decides which roles map to which Vorbis tags.
public struct TrackCredit: Sendable, Equatable {
    public let role: String
    public let name: String

    public init(role: String, name: String) {
        self.role = role
        self.name = name
    }
}
