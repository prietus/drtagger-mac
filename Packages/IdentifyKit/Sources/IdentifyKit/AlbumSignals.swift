import Foundation
import LibraryKit
import ProviderKit
import SACDKit
import SplitKit

public enum SignalOrigin: String, Sendable, Codable, Hashable {
    case artwork
    case tags
    case cue
    case ctdb
    case sacdText
    case folderName
    case fingerprint
}

public struct SignalValue<T: Sendable & Codable & Hashable>: Sendable, Codable, Hashable {
    public let value: T
    public let origin: SignalOrigin
    public let detail: String?

    public init(_ value: T, origin: SignalOrigin, detail: String? = nil) {
        self.value = value
        self.origin = origin
        self.detail = detail
    }
}

// One local track as the scorer sees it: position, title guess, duration.
public struct LocalTrack: Sendable, Codable, Hashable {
    public let index: Int                 // 0-based across the whole album
    public let discNumber: Int
    public let title: String?
    public let durationSeconds: Double?
    public let url: URL?                  // track file, or the image it lives in
    public let imageStart: Double?        // seconds into the image (cue images)

    public init(index: Int, discNumber: Int, title: String?, durationSeconds: Double?, url: URL?, imageStart: Double? = nil) {
        self.index = index
        self.discNumber = discNumber
        self.title = title
        self.durationSeconds = durationSeconds
        self.url = url
        self.imageStart = imageStart
    }
}

// Everything known about the album before asking the providers.
public struct AlbumSignals: Sendable, Codable, Hashable {
    public var barcodes: [SignalValue<String>] = []
    public var catalogNumbers: [SignalValue<String>] = []
    public var mbReleaseIDs: [SignalValue<String>] = []
    public var discID: String?
    public var tocString: String?
    // Release sets: which disc positions the local files cover, the total
    // the set declares (SACD album set, "disc 2-3"), and per-disc IDs.
    public var presentDiscs: [Int] = [1]
    public var declaredDiscTotal: Int?
    public var discIDs: [Int: String] = [:]
    public var tocStrings: [Int: String] = [:]
    public var artistHint: String?
    public var albumHint: String?
    public var yearHint: String?
    public var editionHint: String?                    // "20th Anniversary Edition"
    public var editionYearHint: String?                // year of the pressing / remaster
    public var countryHint: String?                    // ISO code, from folder name or tags
    public var sourceHint: FolderNameParser.SourceHint? // medium named in the folder or MEDIA tag
    public var discCount: Int = 1
    public var tracks: [LocalTrack] = []
    public var existingTags: [String: String] = [:]
    public var artworkScans: [ArtworkScanResult] = []
    public var isDSD: Bool = false
    public var isSACDImage: Bool = false                // a Scarletbook ISO, not loose DSF files
    public var sampleRate: Int?
    public var bitsPerSample: Int?

    public init() {}

    public enum LocalFormat: String, Sendable, Codable {
        case sacd, cd, hiRes, unknown
    }

    // What physical source the local files can come from.
    public var localFormat: LocalFormat {
        if isDSD { return .sacd }
        guard let rate = sampleRate, let bits = bitsPerSample else { return .unknown }
        if rate == 44100 && bits <= 16 { return .cd }
        if rate > 44100 || bits > 16 { return .hiRes }
        return .unknown
    }

    public var trackCount: Int { tracks.count }
    // A partial or declared set: candidates are matched medium by medium.
    public var isSet: Bool { presentDiscs != [1] || declaredDiscTotal != nil }
    public var allDiscIDs: Set<String> { Set(discIDs.values).union(discID.map { [$0] } ?? []) }
    public var uniqueBarcodes: [String] { unique(barcodes.map(\.value)) }
    public var uniqueCatalogNumbers: [String] { unique(catalogNumbers.map(\.value)) }
    public var uniqueReleaseIDs: [String] { unique(mbReleaseIDs.map(\.value)) }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

// Reads signals off the album's files, texts and artwork.
public struct SignalCollector: Sendable {

    public struct Options: Sendable {
        public var scanArtwork = true
        public var maxArtworkFiles = 12
        public init() {}
    }

    public let tool: FFmpegTool

    public init(tool: FFmpegTool) {
        self.tool = tool
    }

    public func collect(
        album: DetectedAlbum,
        toc: DiscTOC? = nil,
        ctdb: [CUEToolsDBClient.Metadata] = [],
        options: Options = Options(),
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> AlbumSignals {
        var s = AlbumSignals()
        s.discCount = album.kind == .sacdISO ? 1 : max(1, album.discs.count)
        let folder = FolderNameParser.parse(album.folderName)
        s.artistHint = folder.artist
        s.albumHint = folder.title
        s.yearHint = folder.year
        s.editionHint = folder.edition
        s.editionYearHint = folder.editionYear
        s.countryHint = folder.country
        s.sourceHint = folder.source
        // Catalog numbers and barcodes people write in the folder name:
        // "(Fantasy FCD 8387-2, Germany)", "[SICP-1700]", "[0602547288042]".
        for note in folder.notes {
            for cat in CatalogNumberParser.extract(from: [note]) {
                s.catalogNumbers.append(SignalValue(cat.formatted, origin: .folderName, detail: note))
            }
            for m in note.matches(of: #/\b(\d{12,14})\b/#) {
                s.barcodes.append(SignalValue(String(m.1), origin: .folderName, detail: note))
            }
        }
        if !folder.notes.isEmpty || folder.edition != nil || folder.source != nil || folder.country != nil {
            var parts: [String] = []
            if let e = folder.edition { parts.append("edition \(e)") }
            if let c = folder.country { parts.append("country \(c)") }
            if let src = folder.source { parts.append("source \(src.rawValue)") }
            if !folder.notes.isEmpty { parts.append("notes \(folder.notes.joined(separator: " | "))") }
            log("Folder name: " + parts.joined(separator: ", ") + ".")
        }

        // CUE texts and hints.
        for disc in album.discs {
            guard let cue = disc.cue else { continue }
            if let b = cue.barcodeHint { s.barcodes.append(SignalValue(b, origin: .cue, detail: disc.cueURL?.lastPathComponent)) }
            for c in cue.catalogNumberHints { s.catalogNumbers.append(SignalValue(c, origin: .cue)) }
            if disc.number == album.discs.first?.number {
                if let p = cue.performer, !p.isEmpty { s.artistHint = p }
                if let t = cue.title, !t.isEmpty { s.albumHint = t }
                if let d = cue.date, d.count >= 4 { s.yearHint = String(d.prefix(4)) }
            }
        }

        // Disc positions: a CD1/CD2 folder covers 1…n; a lone disc that says
        // "disc 2 of 3" covers position 2 of a declared total of 3.
        if album.discs.count > 1 {
            s.presentDiscs = album.discs.map(\.number).sorted()
        } else if let position = album.discPosition, let total = position.total, total > 1 {
            s.presentDiscs = [position.number]
            s.declaredDiscTotal = total
            s.discCount = total
        }

        // Disc TOC and CUETools DB hints.
        if let toc {
            s.discID = toc.musicBrainzDiscID
            s.tocString = toc.musicBrainzTOCString
            if let first = s.presentDiscs.first {
                s.discIDs[first] = toc.musicBrainzDiscID
                s.tocStrings[first] = toc.musicBrainzTOCString
            }
        }
        for m in ctdb where m.source == "musicbrainz" {
            if let id = m.id { s.mbReleaseIDs.append(SignalValue(id, origin: .ctdb, detail: "\(m.artist) – \(m.album)")) }
        }

        // Tracks with durations.
        s.tracks = await localTracks(album: album, toc: toc, log: log)

        // Existing tags (first track file) and SACD texts.
        if album.kind == .sacdISO {
            s.isDSD = true
            s.isSACDImage = true
            if let disc = try? SACDDiscReader.read(url: album.url) {
                if let a = disc.artist { s.artistHint = a }
                if let t = disc.title { s.albumHint = t }
                if let y = disc.year { s.yearHint = y }
                let cat = disc.info.discCatalogNumber
                if !cat.isEmpty { s.catalogNumbers.append(SignalValue(cat, origin: .sacdText)) }
                let boxCat = disc.info.albumCatalogNumber
                if !boxCat.isEmpty, boxCat != cat { s.catalogNumbers.append(SignalValue(boxCat, origin: .sacdText, detail: "album set")) }
            }
        } else if let first = album.discs.first?.trackFiles.first ?? album.discs.first?.imageFile {
            s.isDSD = first.format.isDSD
            if let info = try? await tool.probe(first.url) {
                s.sampleRate = info.sampleRate
                s.bitsPerSample = info.bitsPerSample
            }
            if let tags = try? await tool.probeTags(first.url) {
                s.existingTags = tags
                if let b = tags["BARCODE"] ?? tags["UPC"] ?? tags["EAN"], b.filter(\.isNumber).count >= 8 {
                    s.barcodes.append(SignalValue(b.filter(\.isNumber), origin: .tags))
                }
                for key in ["CATALOGNUMBER", "CATALOG#", "CATNO", "LABELNO"] {
                    if let c = tags[key], !c.isEmpty { s.catalogNumbers.append(SignalValue(c, origin: .tags, detail: key)) }
                }
                if let id = tags["MUSICBRAINZ_ALBUMID"] ?? tags["MUSICBRAINZ ALBUM ID"], id.count == 36 {
                    s.mbReleaseIDs.append(SignalValue(id, origin: .tags))
                }
                if let a = tags["ALBUMARTIST"] ?? tags["ALBUM_ARTIST"] ?? tags["ARTIST"], !a.isEmpty { s.artistHint = a }
                if let t = tags["ALBUM"], !t.isEmpty {
                    // "Meteora (20th Anniversary Edition)" → title + edition.
                    let parsed = FolderNameParser.parseAlbumTitle(t)
                    s.albumHint = parsed.title ?? t
                    if let e = parsed.edition { s.editionHint = e }
                    if let y = parsed.editionYear { s.editionYearHint = y }
                }
                if let d = tags["DATE"] ?? tags["YEAR"], d.count >= 4 { s.yearHint = String(d.prefix(4)) }
                if let y = tags["ORIGINALDATE"] ?? tags["ORIGINALYEAR"], y.count >= 4, s.yearHint != String(y.prefix(4)) {
                    // Picard: DATE is the pressing, ORIGINALDATE the first release.
                    s.editionYearHint = s.yearHint
                    s.yearHint = String(y.prefix(4))
                }
                if let c = tags["RELEASECOUNTRY"], c.count == 2 { s.countryHint = c.uppercased() }
                if let m = tags["MEDIA"]?.lowercased() {
                    if m.contains("sacd") { s.sourceHint = .sacd }
                    else if m.contains("vinyl") { s.sourceHint = .vinyl }
                    else if m.contains("digital") { s.sourceHint = .digital }
                    else if m.contains("dvd") || m.contains("blu-ray") { s.sourceHint = .dvd }
                    else if m.contains("cd") { s.sourceHint = .cd }
                }
            }
        }

        // Artwork: barcodes and catalog numbers.
        if options.scanArtwork {
            let files = Self.prioritisedArtwork(album.artworkFiles, limit: options.maxArtworkFiles)
            let scanner = ArtworkScanner()
            var results: [ArtworkScanResult] = []
            await withTaskGroup(of: ArtworkScanResult?.self) { group in
                var running = 0
                var iterator = files.makeIterator()
                func enqueue() {
                    if let url = iterator.next() {
                        running += 1
                        group.addTask { try? await scanner.scan(url) }
                    }
                }
                for _ in 0..<3 { enqueue() }
                for await r in group {
                    running -= 1
                    if let r { results.append(r) }
                    enqueue()
                }
            }
            results.sort { $0.url.lastPathComponent < $1.url.lastPathComponent }
            s.artworkScans = results
            for r in results {
                for b in r.barcodes { s.barcodes.append(SignalValue(b, origin: .artwork, detail: r.url.lastPathComponent)) }
                for c in r.catalogNumbers { s.catalogNumbers.append(SignalValue(c, origin: .artwork, detail: r.url.lastPathComponent)) }
            }
            let hits = results.filter(\.hasHit).count
            log("Artwork: scanned \(results.count) image(s), \(hits) with a barcode or catalog number.")
        }
        return s
    }

    // MARK: Sets

    public struct SetMember: Sendable {
        public let album: DetectedAlbum
        public let position: Int          // 1-based disc position in the release
        public let toc: DiscTOC?

        public init(album: DetectedAlbum, position: Int, toc: DiscTOC? = nil) {
            self.album = album
            self.position = position
            self.toc = toc
        }
    }

    // Several albums that are one release (a SACD box, "Box Set (Disc 1)"…):
    // every member's signals, tracks in disc order, one disc ID per position.
    public func collect(
        set members: [SetMember],
        declaredTotal: Int?,
        ctdb: [CUEToolsDBClient.Metadata] = [],
        options: Options = Options(),
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> AlbumSignals {
        let ordered = members.sorted { $0.position < $1.position }
        var merged: AlbumSignals? = nil
        var seenBarcodes = Set<String>(), seenCatalogs = Set<String>(), seenMBIDs = Set<String>()
        for member in ordered {
            var part = await collect(album: member.album, toc: member.toc, ctdb: ctdb, options: options, log: log)
            part.tracks = part.tracks.map { LocalTrack(index: $0.index, discNumber: member.position, title: $0.title, durationSeconds: $0.durationSeconds, url: $0.url, imageStart: $0.imageStart) }
            if var m = merged {
                let base = m.tracks.count
                m.tracks += part.tracks.map { LocalTrack(index: base + $0.index, discNumber: $0.discNumber, title: $0.title, durationSeconds: $0.durationSeconds, url: $0.url, imageStart: $0.imageStart) }
                for b in part.barcodes where seenBarcodes.insert(b.value).inserted { m.barcodes.append(b) }
                for c in part.catalogNumbers where seenCatalogs.insert(c.value).inserted { m.catalogNumbers.append(c) }
                for id in part.mbReleaseIDs where seenMBIDs.insert(id.value).inserted { m.mbReleaseIDs.append(id) }
                m.artworkScans += part.artworkScans
                if let id = part.discID { m.discIDs[member.position] = id }
                if let t = part.tocString { m.tocStrings[member.position] = t }
                merged = m
            } else {
                for b in part.barcodes { seenBarcodes.insert(b.value) }
                for c in part.catalogNumbers { seenCatalogs.insert(c.value) }
                for id in part.mbReleaseIDs { seenMBIDs.insert(id.value) }
                part.discIDs = [:]; part.tocStrings = [:]
                if let id = part.discID { part.discIDs[member.position] = id }
                if let t = part.tocString { part.tocStrings[member.position] = t }
                merged = part
            }
        }
        guard var s = merged else { return AlbumSignals() }
        s.presentDiscs = ordered.map(\.position)
        s.declaredDiscTotal = declaredTotal ?? ordered.compactMap { $0.album.discPosition?.total }.max()
        s.discCount = max(s.declaredDiscTotal ?? 0, ordered.map(\.position).max() ?? 1)
        // The box title beats a disc title ("Piano Sonatas" over "Sonatas 1–7").
        if let first = ordered.first?.album, let sacd = first.sacd, let box = sacd.albumTitle, !box.isEmpty {
            s.albumHint = box
            if let artist = sacd.albumArtist, !artist.isEmpty { s.artistHint = artist }
        } else if let first = ordered.first?.album {
            let parsed = FolderNameParser.parse(FileRules.strippingDiscToken(first.folderName))
            if let t = parsed.title, s.albumHint == nil || s.albumHint == FolderNameParser.parse(first.folderName).title { s.albumHint = t }
        }
        log("Release set: discs \(s.presentDiscs.map(String.init).joined(separator: ", ")) of \(s.discCount), \(s.trackCount) track(s).")
        return s
    }

    // Back covers and OBI strips carry the codes; scan those first.
    static func prioritisedArtwork(_ urls: [URL], limit: Int) -> [URL] {
        func rank(_ u: URL) -> Int {
            let n = u.lastPathComponent.lowercased()
            if n.contains("back") || n.contains("rear") || n.contains("trasera") || n.contains("obi") { return 0 }
            if n.contains("inlay") || n.contains("tray") || n.contains("booklet") { return 1 }
            if n.contains("front") || n.contains("cover") || n.contains("folder") || n.contains("frontal") { return 3 }
            return 2
        }
        return Array(urls.sorted { rank($0) < rank($1) }.prefix(limit))
    }

    // MARK: Tracks

    private func localTracks(album: DetectedAlbum, toc: DiscTOC?, log: @escaping @Sendable (String) -> Void) async -> [LocalTrack] {
        var tracks: [LocalTrack] = []
        if album.kind == .sacdISO {
            guard let disc = try? SACDDiscReader.read(url: album.url), let area = disc.stereoArea else { return [] }
            for t in area.tracks {
                tracks.append(LocalTrack(index: tracks.count, discNumber: 1, title: t.title, durationSeconds: t.duration.totalSeconds, url: album.url))
            }
            return tracks
        }
        for disc in album.discs {
            if let image = disc.imageFile, let cue = disc.cue {
                // Durations from the TOC when we have it, else from the CUE and
                // the image length.
                let starts = cue.audioTracks.map { $0.start?.totalSeconds ?? 0 }
                var ends: [Double] = Array(starts.dropFirst())
                if let toc, toc.trackCount == starts.count, album.discs.count == 1 {
                    ends.append(Double(toc.leadOut - DiscTOC.leadInFrames) / 75.0)
                } else if let info = try? await tool.probe(image.url), let d = info.durationSeconds {
                    ends.append(d)
                } else {
                    ends.append(starts.last ?? 0)
                }
                for (i, t) in cue.audioTracks.enumerated() {
                    let dur = max(0, ends[i] - starts[i])
                    tracks.append(LocalTrack(index: tracks.count, discNumber: disc.number, title: t.title, durationSeconds: dur > 0 ? dur : nil, url: image.url, imageStart: starts[i]))
                }
            } else {
                for (i, f) in disc.trackFiles.enumerated() {
                    let info = try? await tool.probe(f.url)
                    let cueTitle = disc.cue?.audioTracks.first { $0.number == i + 1 }?.title
                    tracks.append(LocalTrack(index: tracks.count, discNumber: disc.number, title: cueTitle, durationSeconds: info?.durationSeconds, url: f.url))
                }
            }
        }
        return tracks
    }
}
