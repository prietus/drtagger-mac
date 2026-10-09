import Foundation
import LibraryKit
import ProviderKit

// Answers CDDB-over-HTTP requests (the protocol behind freedb/gnudb) so a
// ripper such as XLD can use drtagger as its "FreeDB" server. Only the
// commands rippers send are implemented: `cddb query`, `cddb read`, `hello`
// and `proto`. Releases come from MusicBrainz's fuzzy TOC lookup, ranked by
// MatchScorer, so the pressing whose durations fit best is listed first.
//
// CDDB carries little: artist, album, year, genre and track titles (plus a
// free-form EXTD line where the label, catalog number, barcode and MBID go).
public actor CDDBResponder {

    public typealias Lookup = @Sendable (DiscTOC) async -> [Candidate]

    // One listed match: CDDB tells matches apart by (category, discid), so
    // every candidate of a query gets its own category.
    struct Entry: Sendable {
        let category: String
        let candidate: Candidate
        let medium: CandidateMedium
    }

    static let categories = ["rock", "misc", "jazz", "classical", "blues", "folk", "country", "newage", "reggae", "soundtrack"]

    private let lookup: Lookup
    private var entries: [String: [Entry]] = [:]   // discid → listed matches
    private var tocs: [String: (offsets: [Int], seconds: Int)] = [:]

    public var maxMatches = 6

    public init(lookup: @escaping Lookup) {
        self.lookup = lookup
    }

    // Live lookup: MusicBrainz fuzzy TOC search (the exact disc ID cannot be
    // computed: CDDB only sends the disc length in whole seconds).
    public init(userAgent: String) {
        let mb = MusicBrainzClient(userAgent: userAgent)
        self.lookup = { toc in
            (try? await mb.lookupDiscID("-", toc: toc.musicBrainzTOCString)) ?? []
        }
    }

    // `query` is the URL query string ("cmd=cddb+query+…&hello=…&proto=6").
    public func respond(toQuery query: String) async -> String {
        let fields = Self.parseForm(query)
        guard let cmd = fields["cmd"] else { return "500 Command syntax error.\n" }
        let words = cmd.split(separator: " ").map(String.init)
        guard let first = words.first?.lowercased() else { return "500 Command syntax error.\n" }
        switch first {
        case "cddb":
            guard words.count >= 2 else { return "500 Command syntax error.\n" }
            switch words[1].lowercased() {
            case "query": return await handleQuery(Array(words.dropFirst(2)))
            case "read": return handleRead(Array(words.dropFirst(2)))
            case "lscat": return "210 OK, category list follows (until terminating `.')\n" + Self.categories.joined(separator: "\n") + "\n.\n"
            default: return "500 Unrecognized command.\n"
            }
        case "proto": return "201 OK, protocol version now: 6\n"
        case "hello": return "200 Hello and welcome.\n"
        case "motd": return "210 Last modified: 01/01/2026 00:00:00 MOTD follows (until terminating `.')\ndrtagger for Mac CDDB service.\n.\n"
        case "stat": return "210 OK, status information follows (until terminating `.')\nCurrent proto: 6\nMax proto: 6\n.\n"
        default: return "500 Unrecognized command.\n"
        }
    }

    // cddb query <discid> <ntrks> <off1> … <offN> <nsecs>
    private func handleQuery(_ args: [String]) async -> String {
        guard args.count >= 3, let n = Int(args[1]), n > 0, args.count == n + 3,
              let seconds = Int(args[n + 2]) else { return "500 Command syntax error.\n" }
        let discid = args[0].lowercased()
        let offsets = args[2..<(2 + n)].compactMap { Int($0) }
        guard offsets.count == n else { return "500 Command syntax error.\n" }
        tocs[discid] = (offsets, seconds)
        let toc = DiscTOC(firstTrack: 1, lastTrack: n, trackOffsets: offsets, leadOut: seconds * 75)

        // Local durations from the TOC, for the scorer.
        var signals = AlbumSignals()
        let ends = Array(offsets.dropFirst()) + [seconds * 75]
        signals.tracks = offsets.enumerated().map { i, o in
            LocalTrack(index: i, discNumber: 1, title: nil, durationSeconds: Double(ends[i] - o) / 75, url: nil)
        }
        signals.sampleRate = 44100
        signals.bitsPerSample = 16

        var ranked: [(Double, Candidate, CandidateMedium)] = []
        for c in await lookup(toc) {
            guard let medium = Self.bestMedium(c, durations: signals.tracks.compactMap(\.durationSeconds)) else { continue }
            let single = Candidate(source: c.source, providerID: c.providerID, releaseGroupID: c.releaseGroupID, title: c.title, artist: c.artist,
                                   year: c.year, country: c.country, label: c.label, catalogNumber: c.catalogNumber, mediaFormat: medium.format,
                                   trackCount: medium.tracks.count, disambiguation: c.disambiguation, tracks: medium.tracks,
                                   releasedDate: c.releasedDate, barcode: c.barcode, media: [medium], status: c.status, primaryType: c.primaryType)
            let score = MatchScorer.score(single, signals: signals, origins: [.tocMatch], fingerprintVote: nil, fingerprintedTracks: 0).score
            ranked.append((score, c, medium))
        }
        ranked.sort { $0.0 > $1.0 }
        let list = ranked.prefix(min(maxMatches, Self.categories.count)).enumerated().map { i, r in
            Entry(category: Self.categories[i], candidate: r.1, medium: r.2)
        }
        entries[discid] = list
        guard !list.isEmpty else { return "202 No match found.\n" }
        if list.count == 1, let e = list.first {
            return "200 \(e.category) \(discid) \(Self.dtitle(e))\n"
        }
        // The list is only shown to the user to pick from (the entry itself
        // comes from `cddb read`), so it says which pressing each one is.
        var out = "211 Found inexact matches, list follows (until terminating `.')\n"
        for e in list { out += "\(e.category) \(discid) \(Self.dtitle(e))\(Self.edition(e))\n" }
        return out + ".\n"
    }

    // cddb read <category> <discid>
    private func handleRead(_ args: [String]) -> String {
        guard args.count >= 2 else { return "500 Command syntax error.\n" }
        let category = args[0].lowercased(), discid = args[1].lowercased()
        guard let entry = entries[discid]?.first(where: { $0.category == category }) else {
            return "401 \(category) \(discid) No such CD entry in database.\n"
        }
        let c = entry.candidate, m = entry.medium
        var out = "210 \(category) \(discid) CD database entry follows (until terminating `.')\n"
        out += "# xmcd\n#\n# Track frame offsets:\n"
        if let toc = tocs[discid] {
            for o in toc.offsets { out += "#\t\(o)\n" }
            out += "#\n# Disc length: \(toc.seconds) seconds\n"
        }
        out += "#\n# Revision: 0\n# Submitted via: drtagger-mac\n#\n"
        out += "DISCID=\(discid)\n"
        out += Self.field("DTITLE", Self.dtitle(entry))
        out += Self.field("DYEAR", c.year ?? "")
        out += Self.field("DGENRE", c.genres.first ?? "")
        for (i, t) in m.tracks.enumerated() {
            let title = t.artist.map { "\($0) / \(t.title)" } ?? t.title
            out += Self.field("TTITLE\(i)", title)
        }
        var extd: [String] = []
        if let l = c.label { extd.append(l) }
        if let cat = c.catalogNumber { extd.append(cat) }
        if let country = c.country { extd.append(country) }
        if let b = c.barcode { extd.append("Barcode \(b)") }
        if let f = m.format { extd.append(f) }
        if c.source == .musicbrainz { extd.append("MusicBrainz release \(c.providerID)") }
        out += Self.field("EXTD", extd.joined(separator: " · "))
        for i in m.tracks.indices { out += "EXTT\(i)=\n" }
        out += "PLAYORDER=\n.\n"
        return out
    }

    // MARK: Helpers

    // The medium of a (possibly multi-disc or hybrid) release that matches
    // the queried disc: same track count, durations closest.
    static func bestMedium(_ c: Candidate, durations: [Double]) -> CandidateMedium? {
        let media = c.media.isEmpty ? [CandidateMedium(position: 1, tracks: c.tracks)] : c.media
        let fitting = media.filter { $0.tracks.count == durations.count }
        func error(_ m: CandidateMedium) -> Double {
            zip(m.tracks, durations).reduce(0) { acc, p in acc + abs(Double(p.0.durationMS ?? 0) / 1000 - p.1) }
        }
        return fitting.min { error($0) < error($1) }
    }

    static func edition(_ e: Entry) -> String {
        let c = e.candidate
        let parts = [c.year, c.country, e.medium.format, c.catalogNumber].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? "" : " [" + parts.joined(separator: " · ") + "]"
    }

    static func dtitle(_ e: Entry) -> String {
        "\(e.candidate.artist) / \(e.candidate.title)".replacingOccurrences(of: "\n", with: " ")
    }

    // xmcd lines are limited to 256 bytes; longer values repeat the key.
    static func field(_ key: String, _ value: String) -> String {
        let clean = value.replacingOccurrences(of: "\n", with: " ")
        var out = "", chunk = ""
        for ch in clean {
            if (key.utf8.count + 1 + chunk.utf8.count + String(ch).utf8.count) > 250 {
                out += "\(key)=\(chunk)\n"; chunk = ""
            }
            chunk.append(ch)
        }
        return out + "\(key)=\(chunk)\n"
    }

    // application/x-www-form-urlencoded: "+" is a space, then %-decoding.
    static func parseForm(_ query: String) -> [String: String] {
        var fields: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard let key = parts.first else { continue }
            let raw = parts.count > 1 ? parts[1] : ""
            fields[key.lowercased()] = raw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? raw
        }
        return fields
    }
}
