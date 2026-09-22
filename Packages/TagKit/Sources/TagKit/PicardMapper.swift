import Foundation
import ProviderKit

// What the mapper knows beyond the candidate: disc IDs computed locally,
// AcoustID results per track, and the Discogs release chosen for credits.
public struct TagContext: Sendable {
    public var discogs: Candidate?
    public var musicBrainzDiscID: String?
    public var freedbDiscID: String?
    public var acoustIDs: [Int: String] = [:]          // by 0-based album track index
    public var fingerprints: [Int: String] = [:]
    public var writeFingerprints = false
    public var writeGenres = true
    public var includeDiscogsCredits = true

    public init() {}
}

// Candidate → Picard tags. Album-level fields are repeated on every track
// (that is how Vorbis/ID3 work); track fields come from the medium the
// local files map to, so a hybrid SACD rip gets the SACD layer's numbering.
public enum PicardMapper {

    public static let variousArtistsID = "89ad4ac3-39f7-470e-963a-56509c546377"

    public static func albumTags(_ c: Candidate, media: [CandidateMedium], context: TagContext) -> TagSet {
        var t = TagSet()
        t.set(TagField.album, c.title)
        t.set(TagField.albumArtist, c.artist)
        t.set(TagField.albumArtistSort, c.artistSort)
        for id in c.artistIDs { t.add(TagField.mbAlbumArtistID, id) }
        t.set(TagField.date, c.releasedDate ?? c.year)
        if let original = c.firstReleaseDate {
            t.set(TagField.originalDate, original)
            t.set(TagField.originalYear, String(original.prefix(4)))
        }
        for label in split(c.label) { t.add(TagField.label, label) }
        for cat in c.catalogNumbers { t.add(TagField.catalogNumber, cat) }
        t.set(TagField.barcode, c.barcode)
        t.set(TagField.releaseCountry, c.country)
        t.set(TagField.releaseStatus, c.status?.lowercased())
        if let primary = c.primaryType { t.add(TagField.releaseType, primary.lowercased()) }
        for secondary in c.secondaryTypes { t.add(TagField.releaseType, secondary.lowercased()) }
        t.set(TagField.script, c.script)
        let discCount = max(1, media.count)
        t.set(TagField.discTotal, String(discCount))
        t.set(TagField.totalDiscs, String(discCount))
        if c.source == .musicbrainz {
            t.set(TagField.mbAlbumID, c.providerID)
            t.set(TagField.mbReleaseGroupID, c.releaseGroupID)
        }
        t.set(TagField.mbDiscID, context.musicBrainzDiscID)
        t.set(TagField.discID, context.freedbDiscID)
        if c.artistIDs.contains(variousArtistsID) || c.artist.lowercased() == "various artists" {
            t.set(TagField.compilation, "1")
        }
        if context.writeGenres {
            let source = c.genres.isEmpty ? context.discogs : c
            for g in source?.genres ?? [] { t.add(TagField.genre, g) }
            for s in source?.styles ?? [] { t.add(TagField.style, s) }
        }
        return t
    }

    // Tags for the local track at `index` (0-based across the whole album).
    public static func trackTags(_ c: Candidate, media: [CandidateMedium], index: Int, context: TagContext) -> TagSet? {
        let list = media.isEmpty ? [CandidateMedium(position: 1, tracks: c.tracks)] : media
        var cursor = 0
        for (discIndex, medium) in list.enumerated() {
            if index < cursor + medium.tracks.count {
                let track = medium.tracks[index - cursor]
                var t = albumTags(c, media: media, context: context)
                fill(&t, track: track, medium: medium, discNumber: discIndex + 1, index: index, candidate: c, context: context)
                return t
            }
            cursor += medium.tracks.count
        }
        return nil
    }

    // Tags for track `track` (0-based) of the medium at 1-based position
    // `disc` among `media`: what a set member's files map to.
    public static func trackTags(_ c: Candidate, media: [CandidateMedium], disc: Int, track: Int, context: TagContext) -> TagSet? {
        let list = media.isEmpty ? [CandidateMedium(position: 1, tracks: c.tracks)] : media
        guard disc >= 1, disc <= list.count, track >= 0, track < list[disc - 1].tracks.count else { return nil }
        let index = list.prefix(disc - 1).reduce(0) { $0 + $1.tracks.count } + track
        var t = albumTags(c, media: media, context: context)
        fill(&t, track: list[disc - 1].tracks[track], medium: list[disc - 1], discNumber: disc, index: index, candidate: c, context: context)
        return t
    }

    private static func fill(_ t: inout TagSet, track: CandidateTrack, medium: CandidateMedium, discNumber: Int, index: Int, candidate c: Candidate, context: TagContext) {
        t.set(TagField.title, track.title)
        let credits = track.artistCredits.isEmpty ? c.artistCredits : track.artistCredits
        t.set(TagField.artist, track.artist ?? c.artist)
        t.set(TagField.artistSort, credits.isEmpty ? c.artistSort : ArtistCredit.sortJoined(credits))
        for credit in credits { t.add(TagField.artists, credit.name) }
        for id in credits.compactMap(\.artistID) { t.add(TagField.mbArtistID, id) }
        t.set(TagField.trackNumber, String(track.position))
        t.set(TagField.trackTotal, String(medium.tracks.count))
        t.set(TagField.totalTracks, String(medium.tracks.count))
        t.set(TagField.discNumber, String(discNumber))
        t.set(TagField.discSubtitle, medium.title)
        t.set(TagField.media, medium.format)
        for isrc in track.isrcs { t.add(TagField.isrc, isrc) }
        if c.source == .musicbrainz {
            t.set(TagField.mbTrackID, track.recordingID)
            t.set(TagField.mbReleaseTrackID, track.trackID)
        }
        for work in track.works {
            t.add(TagField.work, work.title)
            t.add(TagField.mbWorkID, work.id)
        }
        for (field, value) in creditFields(track.credits) { t.add(field, value) }
        if context.includeDiscogsCredits, let discogs = context.discogs, discogs.id != c.id {
            let dtracks = discogs.allTracks
            if index < dtracks.count, dtracks.count == (c.allTracks.isEmpty ? dtracks.count : c.allTracks.count) {
                for (field, value) in creditFields(dtracks[index].credits) { t.add(field, value) }
            }
        }
        t.set(TagField.acoustID, context.acoustIDs[index])
        if context.writeFingerprints { t.set(TagField.acoustIDFingerprint, context.fingerprints[index]) }
    }

    // Role/name credits (MusicBrainz relationships or Discogs extra artists)
    // → Picard fields. Instruments and vocals become PERFORMER "Name (role)".
    public static func creditFields(_ credits: [TrackCredit]) -> [(String, String)] {
        var out: [(String, String)] = []
        for credit in credits {
            for role in credit.role.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !role.isEmpty {
                let key = normalizedRole(role)
                switch key {
                case "composer", "composed by", "music by": out.append((TagField.composer, credit.name))
                case "lyricist", "lyrics by", "words by", "librettist": out.append((TagField.lyricist, credit.name))
                case "writer", "written-by", "written by", "songwriter": out.append((TagField.writer, credit.name))
                case "arranger", "arranged by", "orchestrator", "orchestrated by": out.append((TagField.arranger, credit.name))
                case "conductor", "conducted by": out.append((TagField.conductor, credit.name))
                case "producer", "produced by", "co-producer", "executive producer", "executive-producer": out.append((TagField.producer, credit.name))
                case "engineer", "recorded by", "recording engineer", "recording", "mastered by", "mastering", "mastering engineer": out.append((TagField.engineer, credit.name))
                case "mixer", "mixed by", "mix": out.append((TagField.mixer, credit.name))
                case "remixer", "remix", "remixed by": out.append((TagField.remixer, credit.name))
                case "performer": out.append((TagField.performer, credit.name))
                default: out.append((TagField.performer, "\(credit.name) (\(key))"))
                }
            }
        }
        return out
    }

    // "Guitar [Acoustic]" → "acoustic guitar"; "Vocals" → "vocals".
    static func normalizedRole(_ raw: String) -> String {
        var role = raw.lowercased().trimmingCharacters(in: .whitespaces)
        if let open = role.firstIndex(of: "["), let close = role.firstIndex(of: "]"), open < close {
            let qualifier = role[role.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            let base = role[..<open].trimmingCharacters(in: .whitespaces)
            role = qualifier.isEmpty ? base : "\(qualifier) \(base)"
        }
        return role
    }

    private static func split(_ joined: String?) -> [String] {
        (joined ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
