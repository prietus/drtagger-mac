import FLACKit
import Foundation
import LibraryKit

// Tags written to freshly split tracks straight from the CUE sheet, so the
// files are playable and sortable before any online identification. The
// identification phases overwrite these with provider data.
public enum ProvisionalTags {

    public static let vendor = "drtagger for Mac"

    public struct AlbumContext: Sendable, Equatable {
        public var album: String?
        public var albumArtist: String?
        public var date: String?
        public var genre: String?
        public var discNumber: Int?
        public var discTotal: Int?
        public var discID: String?          // FreeDB id (REM DISCID)
        public var musicBrainzDiscID: String?
        public var barcode: String?

        public init(album: String? = nil, albumArtist: String? = nil, date: String? = nil, genre: String? = nil,
                    discNumber: Int? = nil, discTotal: Int? = nil, discID: String? = nil,
                    musicBrainzDiscID: String? = nil, barcode: String? = nil) {
            self.album = album
            self.albumArtist = albumArtist
            self.date = date
            self.genre = genre
            self.discNumber = discNumber
            self.discTotal = discTotal
            self.discID = discID
            self.musicBrainzDiscID = musicBrainzDiscID
            self.barcode = barcode
        }

        public static func from(cue: CueSheet, discNumber: Int? = nil, discTotal: Int? = nil, toc: DiscTOC? = nil) -> AlbumContext {
            AlbumContext(
                album: cue.title,
                albumArtist: cue.performer,
                date: cue.date,
                genre: cue.genre,
                discNumber: discNumber,
                discTotal: discTotal,
                discID: cue.discID ?? toc?.freeDBDiscID,
                musicBrainzDiscID: toc?.musicBrainzDiscID,
                barcode: cue.barcodeHint
            )
        }
    }

    public static func comment(for track: SplitTrack, trackTotal: Int, album: AlbumContext) -> VorbisComment {
        var fields: [(name: String, value: String)] = []
        func add(_ name: String, _ value: String?) {
            guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return }
            fields.append((name, v))
        }
        add("TITLE", track.isHiddenTrack ? "Hidden Track" : (track.title ?? "Track \(track.number)"))
        add("ARTIST", track.performer ?? album.albumArtist)
        add("ALBUM", album.album)
        add("ALBUMARTIST", album.albumArtist)
        add("TRACKNUMBER", String(track.number))
        add("TRACKTOTAL", String(trackTotal))
        if let n = album.discNumber { add("DISCNUMBER", String(n)) }
        if let t = album.discTotal { add("DISCTOTAL", String(t)) }
        add("DATE", album.date)
        add("GENRE", album.genre)
        add("ISRC", track.isrc)
        add("BARCODE", album.barcode)
        add("MUSICBRAINZ_DISCID", album.musicBrainzDiscID)
        add("DISCID", album.discID)
        return VorbisComment(vendor: vendor, fields: fields)
    }

    // Rewrites the file's metadata section with `comment`, audio untouched.
    public static func write(_ comment: VorbisComment, to url: URL) throws {
        let source = try FileHandleDataSource(url: url)
        let file = try FLACFile(source: source)
        let data = try file.rewritten(with: comment, source: source)
        let tmp = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}
