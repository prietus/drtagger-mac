import Foundation

// Picard field names as used in Vorbis comments. Every container maps
// these names to its own frames/atoms/items; the app only ever sees this
// flat schema.
public enum TagField {
    public static let title = "TITLE"
    public static let artist = "ARTIST"
    public static let artistSort = "ARTISTSORT"
    public static let artists = "ARTISTS"
    public static let album = "ALBUM"
    public static let albumSort = "ALBUMSORT"
    public static let albumArtist = "ALBUMARTIST"
    public static let albumArtistSort = "ALBUMARTISTSORT"
    public static let date = "DATE"
    public static let originalDate = "ORIGINALDATE"
    public static let originalYear = "ORIGINALYEAR"
    public static let trackNumber = "TRACKNUMBER"
    public static let trackTotal = "TRACKTOTAL"
    public static let totalTracks = "TOTALTRACKS"
    public static let discNumber = "DISCNUMBER"
    public static let discTotal = "DISCTOTAL"
    public static let totalDiscs = "TOTALDISCS"
    public static let discSubtitle = "DISCSUBTITLE"
    public static let label = "LABEL"
    public static let catalogNumber = "CATALOGNUMBER"
    public static let barcode = "BARCODE"
    public static let media = "MEDIA"
    public static let releaseCountry = "RELEASECOUNTRY"
    public static let releaseStatus = "RELEASESTATUS"
    public static let releaseType = "RELEASETYPE"
    public static let script = "SCRIPT"
    public static let compilation = "COMPILATION"
    public static let isrc = "ISRC"
    public static let genre = "GENRE"
    public static let style = "STYLE"
    public static let composer = "COMPOSER"
    public static let composerSort = "COMPOSERSORT"
    public static let lyricist = "LYRICIST"
    public static let writer = "WRITER"
    public static let arranger = "ARRANGER"
    public static let conductor = "CONDUCTOR"
    public static let performer = "PERFORMER"
    public static let producer = "PRODUCER"
    public static let engineer = "ENGINEER"
    public static let mixer = "MIXER"
    public static let remixer = "REMIXER"
    public static let work = "WORK"
    public static let comment = "COMMENT"
    public static let mbAlbumID = "MUSICBRAINZ_ALBUMID"
    public static let mbAlbumArtistID = "MUSICBRAINZ_ALBUMARTISTID"
    public static let mbArtistID = "MUSICBRAINZ_ARTISTID"
    public static let mbTrackID = "MUSICBRAINZ_TRACKID"            // recording MBID (Picard naming)
    public static let mbReleaseTrackID = "MUSICBRAINZ_RELEASETRACKID"
    public static let mbReleaseGroupID = "MUSICBRAINZ_RELEASEGROUPID"
    public static let mbWorkID = "MUSICBRAINZ_WORKID"
    public static let mbDiscID = "MUSICBRAINZ_DISCID"
    public static let discID = "DISCID"                             // FreeDB
    public static let acoustID = "ACOUSTID_ID"
    public static let acoustIDFingerprint = "ACOUSTID_FINGERPRINT"

    // Display / write order: the human fields first, identifiers last.
    public static let canonicalOrder: [String] = [
        title, artist, artistSort, artists, album, albumSort, albumArtist, albumArtistSort,
        date, originalDate, originalYear, trackNumber, trackTotal, totalTracks, discNumber, discTotal, totalDiscs, discSubtitle,
        label, catalogNumber, barcode, media, releaseCountry, releaseStatus, releaseType, script, compilation, isrc,
        genre, style, composer, composerSort, lyricist, writer, arranger, conductor, performer, producer, engineer, mixer, remixer, work,
        comment, mbAlbumID, mbAlbumArtistID, mbArtistID, mbTrackID, mbReleaseTrackID, mbReleaseGroupID, mbWorkID, mbDiscID, discID,
        acoustID, acoustIDFingerprint,
    ]

    // Fields that describe *which release* the file is: stale values from
    // a previous tagging are wrong once a new release is chosen, so a merge
    // clears them when the new candidate does not provide them.
    public static let identityFields: Set<String> = [
        date, originalDate, originalYear, label, catalogNumber, barcode, media, releaseCountry, releaseStatus, releaseType, script,
        isrc, mbAlbumID, mbAlbumArtistID, mbArtistID, mbTrackID, mbReleaseTrackID, mbReleaseGroupID, mbWorkID, mbDiscID, discID,
        discSubtitle, work, artists,
    ]
}

// A flat, multi-valued tag map keyed by upper-case Picard names.
public struct TagSet: Sendable, Equatable, Hashable, Codable {
    public private(set) var fields: [String: [String]] = [:]

    public init() {}

    public init(_ pairs: [(String, String)]) {
        for (name, value) in pairs { add(name, value) }
    }

    public subscript(name: String) -> [String] {
        get { fields[name.uppercased()] ?? [] }
        set {
            let key = name.uppercased()
            let values = newValue.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if values.isEmpty { fields[key] = nil } else { fields[key] = values }
        }
    }

    public func first(_ name: String) -> String? { self[name].first }

    public mutating func set(_ name: String, _ value: String?) {
        self[name] = value.map { [$0] } ?? []
    }

    public mutating func add(_ name: String, _ value: String?) {
        guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return }
        var values = self[name]
        if !values.contains(v) { values.append(v) }
        self[name] = values
    }

    public mutating func remove(_ name: String) { self[name] = [] }

    public var isEmpty: Bool { fields.isEmpty }

    // Names in canonical order, unknown ones alphabetically after.
    public var names: [String] {
        let known = TagField.canonicalOrder.filter { fields[$0] != nil }
        let rest = fields.keys.filter { !TagField.canonicalOrder.contains($0) }.sorted()
        return known + rest
    }

    // (name, value) pairs in write order, one per value.
    public var pairs: [(name: String, value: String)] {
        names.flatMap { name in self[name].map { (name, $0) } }
    }
}
