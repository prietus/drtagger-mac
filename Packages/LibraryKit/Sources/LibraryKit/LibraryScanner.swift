import Foundation

public enum AlbumKind: String, Sendable, Codable, CaseIterable {
    case sacdISO          // one Scarletbook image
    case cueImage         // one audio/raw image file described by a CUE
    case cueMultiFile     // a CUE whose FILE entries all exist (one per track)
    case trackFolder      // loose track files (a CUE may exist as a hint)

    public var displayName: String {
        switch self {
        case .sacdISO: return "SACD ISO"
        case .cueImage: return "CD image + CUE"
        case .cueMultiFile: return "Tracks + CUE"
        case .trackFolder: return "Track folder"
        }
    }
}

public struct DetectedTrackFile: Sendable, Equatable, Codable, Hashable {
    public let url: URL
    public let format: AudioFormat
    public let fileSize: Int64

    public init(url: URL, format: AudioFormat, fileSize: Int64) {
        self.url = url
        self.format = format
        self.fileSize = fileSize
    }

    public var fileName: String { url.lastPathComponent }
}

// One disc of an album: a folder (or the album folder itself) with either
// an image + CUE, or track files.
public struct DetectedDisc: Sendable, Equatable, Codable, Hashable {
    public var number: Int
    public var folder: URL
    public var cueURL: URL?
    public var cue: CueSheet?
    public var imageFile: DetectedTrackFile?     // set for cueImage discs
    public var trackFiles: [DetectedTrackFile]   // set for track / multi-file discs
    public var artworkFiles: [URL]
    public var logFiles: [URL]

    public init(number: Int, folder: URL) {
        self.number = number
        self.folder = folder
        self.trackFiles = []
        self.artworkFiles = []
        self.logFiles = []
    }

    public var trackCount: Int {
        if let cue, imageFile != nil { return cue.audioTracks.count }
        return trackFiles.count
    }
}

public struct DetectedAlbum: Sendable, Equatable, Codable, Hashable, Identifiable {
    public var url: URL                 // album folder, or the ISO file itself
    public var kind: AlbumKind
    public var discs: [DetectedDisc]
    public var sacd: SACDInfo?
    public var isoFile: DetectedTrackFile?
    public var artworkFiles: [URL]      // album-level scans (folder + Scans/ etc.)

    public var id: String { url.standardizedFileURL.path }

    public init(url: URL, kind: AlbumKind, discs: [DetectedDisc] = [], sacd: SACDInfo? = nil, isoFile: DetectedTrackFile? = nil, artworkFiles: [URL] = []) {
        self.url = url
        self.kind = kind
        self.discs = discs
        self.sacd = sacd
        self.isoFile = isoFile
        self.artworkFiles = artworkFiles
    }

    public var trackCount: Int {
        if let sacd { return sacd.trackCount }
        return discs.reduce(0) { $0 + $1.trackCount }
    }

    public var folderName: String {
        if kind == .sacdISO { return url.deletingPathExtension().lastPathComponent }
        // sacd_extract and similar tools write "Album/Stereo/…" and
        // "Album/Multichannel/…": the album is the parent folder.
        if Self.isAreaFolderName(url.lastPathComponent) { return url.deletingLastPathComponent().lastPathComponent }
        return url.lastPathComponent
    }

    public static func isAreaFolderName(_ name: String) -> Bool {
        let n = name.lowercased().trimmingCharacters(in: .whitespaces)
        return ["stereo", "multichannel", "multi-channel", "multi channel", "mch", "2ch", "5ch", "6ch", "2.0", "5.1", "surround", "2ch stereo", "5.1ch"].contains(n)
    }

    // "Disc 2 of 3" evidence: the SACD master TOC's album set, else a disc
    // token in the folder or ISO name. Used to group siblings into one release.
    public var discPosition: (number: Int, total: Int?)? {
        if let sacd, sacd.albumSetSize > 1 { return (sacd.albumSequenceNumber, sacd.albumSetSize) }
        if discs.count > 1 { return nil }
        return FileRules.discNumber(fromFileName: folderName)
    }

    // What siblings of one set share: the name without its disc token, or
    // the SACD album title.
    public var setBaseName: String {
        if let sacd, sacd.albumSetSize > 1, let title = sacd.albumTitle, !title.isEmpty { return FileRules.strippingDiscToken(title) }
        return FileRules.strippingDiscToken(folderName)
    }

    // Best available title / artist without any network lookup.
    public var titleHint: String? {
        if let t = sacd?.title { return t }
        if let t = discs.first?.cue?.title, !t.isEmpty {
            // "Box Set (Disc 1)" names the disc, not the multi-disc album.
            return discs.count > 1 ? FileRules.strippingDiscToken(t) : t
        }
        return FolderNameParser.parse(folderName).displayTitle
    }

    public var artistHint: String? {
        if let a = sacd?.artist { return a }
        if let a = discs.first?.cue?.performer, !a.isEmpty { return a }
        return FolderNameParser.parse(folderName).artist
    }

    public var yearHint: String? {
        if let d = sacd?.discDate { return String(d.prefix(4)) }
        if let d = discs.first?.cue?.date, d.count >= 4 { return String(d.prefix(4)) }
        return FolderNameParser.parse(folderName).year
    }

    public var formats: Set<AudioFormat> {
        var set = Set<AudioFormat>()
        for disc in discs {
            if let img = disc.imageFile { set.insert(img.format) }
            for t in disc.trackFiles { set.insert(t.format) }
        }
        return set
    }
}

public struct ScanIssue: Sendable, Equatable, Codable, Hashable {
    public let url: URL
    public let message: String

    public init(url: URL, message: String) {
        self.url = url
        self.message = message
    }
}

public struct ScanResult: Sendable, Equatable {
    public var albums: [DetectedAlbum]
    public var issues: [ScanIssue]
    public var foldersVisited: Int

    public init(albums: [DetectedAlbum] = [], issues: [ScanIssue] = [], foldersVisited: Int = 0) {
        self.albums = albums
        self.issues = issues
        self.foldersVisited = foldersVisited
    }
}

// Walks folders and turns them into DetectedAlbums. Synchronous and
// Sendable; callers run it off the main actor.
public struct LibraryScanner: Sendable {

    public typealias Progress = @Sendable (URL) -> Void

    public init() {}

    public func scan(_ roots: [URL], progress: Progress? = nil) -> ScanResult {
        var result = ScanResult()
        var seen = Set<String>()
        for root in roots {
            let std = root.standardizedFileURL
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: std.path, isDirectory: &isDir) else {
                result.issues.append(ScanIssue(url: std, message: "Path does not exist."))
                continue
            }
            if isDir.boolValue {
                walk(std, into: &result, progress: progress)
            } else {
                scanSingleFile(std, into: &result)
            }
        }
        result.albums = result.albums.filter { seen.insert($0.id).inserted }
        return result
    }

    // A dropped file: an ISO, a CUE, or one audio file whose folder is the album.
    private func scanSingleFile(_ url: URL, into result: inout ScanResult) {
        if FileRules.isISO(url) {
            if let album = sacdAlbum(for: url, into: &result) {
                result.albums.append(album)
            }
            return
        }
        if FileRules.isCue(url) || FileRules.isAudio(url) {
            walk(url.deletingLastPathComponent(), into: &result, progress: nil)
            return
        }
        result.issues.append(ScanIssue(url: url, message: "Unsupported file type."))
    }

    // MARK: - Folder walk

    private struct FolderContents {
        var subfolders: [URL] = []
        var isos: [URL] = []
        var cues: [URL] = []
        var audio: [URL] = []
        var artwork: [URL] = []
        var logs: [URL] = []
        var others: [URL] = []
    }

    private func list(_ folder: URL) -> FolderContents {
        var c = FolderContents()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return c }
        for entry in entries {
            let name = entry.lastPathComponent
            if FileRules.isJunk(name: name) { continue }
            let values = try? entry.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                c.subfolders.append(entry)
            } else if values?.isRegularFile == true {
                if FileRules.isISO(entry) { c.isos.append(entry) }
                else if FileRules.isCue(entry) { c.cues.append(entry) }
                else if FileRules.isAudio(entry) { c.audio.append(entry) }
                else if FileRules.isArtwork(entry) { c.artwork.append(entry) }
                else if FileRules.isLog(entry) { c.logs.append(entry) }
                else { c.others.append(entry) }
            }
        }
        c.subfolders = c.subfolders.naturallySorted()
        c.isos = c.isos.naturallySorted()
        c.cues = c.cues.naturallySorted()
        c.audio = c.audio.naturallySorted()
        c.artwork = c.artwork.naturallySorted()
        c.logs = c.logs.naturallySorted()
        return c
    }

    private func walk(_ folder: URL, into result: inout ScanResult, progress: Progress?) {
        progress?(folder)
        result.foldersVisited += 1
        let contents = list(folder)

        // SACD images are always their own album.
        for iso in contents.isos {
            if let album = sacdAlbum(for: iso, into: &result) {
                result.albums.append(album)
            }
        }

        let albums = albumsInFolder(folder, contents: contents, into: &result)
        result.albums.append(contentsOf: albums)

        // Multi-disc: no album here, but disc subfolders that each hold one.
        var consumed = Set<String>()
        if albums.isEmpty {
            if let multi = multiDiscAlbum(folder, contents: contents, into: &result) {
                result.albums.append(multi)
                for disc in multi.discs { consumed.insert(disc.folder.standardizedFileURL.path) }
            }
        }

        for sub in contents.subfolders where !consumed.contains(sub.standardizedFileURL.path) {
            walk(sub, into: &result, progress: progress)
        }
    }

    // Albums formed by the files directly inside `folder` (not counting ISOs).
    private func albumsInFolder(_ folder: URL, contents: FolderContents, into result: inout ScanResult) -> [DetectedAlbum] {
        var albums: [DetectedAlbum] = []
        var handledAudio = Set<String>()
        var orphanCue: (URL, CueSheet)? = nil
        let artwork = collectArtwork(folder, contents: contents)

        for cueURL in contents.cues {
            let sheet: CueSheet
            do {
                sheet = try CueSheet.parse(url: cueURL)
            } catch {
                result.issues.append(ScanIssue(url: cueURL, message: "CUE could not be parsed: \(error.localizedDescription)"))
                continue
            }
            let refs = sheet.referencedFiles(relativeTo: folder)
            let existing = refs.filter { FileManager.default.fileExists(atPath: $0.path) }

            if refs.count == 1, existing.count == 1, let image = trackFile(existing[0], allowRaw: true) {
                var disc = DetectedDisc(number: 1, folder: folder)
                disc.cueURL = cueURL
                disc.cue = sheet
                disc.imageFile = image
                disc.artworkFiles = artwork
                disc.logFiles = contents.logs
                handledAudio.insert(image.url.standardizedFileURL.path)
                albums.append(DetectedAlbum(url: folder, kind: .cueImage, discs: [disc], artworkFiles: artwork))
            } else if refs.count > 1, existing.count == refs.count {
                var disc = DetectedDisc(number: 1, folder: folder)
                disc.cueURL = cueURL
                disc.cue = sheet
                disc.trackFiles = existing.compactMap { trackFile($0, allowRaw: false) }
                disc.artworkFiles = artwork
                disc.logFiles = contents.logs
                for t in disc.trackFiles { handledAudio.insert(t.url.standardizedFileURL.path) }
                albums.append(DetectedAlbum(url: folder, kind: .cueMultiFile, discs: [disc], artworkFiles: artwork))
            } else {
                // Image was split or converted after ripping: keep the sheet
                // as metadata for the loose tracks in this folder.
                if orphanCue == nil { orphanCue = (cueURL, sheet) }
                let missing = refs.count - existing.count
                result.issues.append(ScanIssue(url: cueURL, message: "CUE references \(missing) missing file(s); using it as a hint only."))
            }
        }

        let loose = contents.audio.filter { !handledAudio.contains($0.standardizedFileURL.path) }
        if !loose.isEmpty {
            var disc = DetectedDisc(number: 1, folder: folder)
            disc.trackFiles = loose.compactMap { trackFile($0, allowRaw: false) }
            disc.artworkFiles = artwork
            disc.logFiles = contents.logs
            if let (cueURL, sheet) = orphanCue {
                disc.cueURL = cueURL
                disc.cue = sheet
            }
            albums.append(DetectedAlbum(url: folder, kind: .trackFolder, discs: [disc], artworkFiles: artwork))
        }

        // Several images in one folder: "(Disc 1)", "(Disc 2)"… are one
        // multi-disc album; images without a disc number cannot be told apart
        // from unrelated albums, so only the first is kept and the rest reported.
        let images = albums.filter { $0.kind == .cueImage }
        if images.count > 1 {
            let numbered = images.compactMap { a -> (Int, DetectedAlbum)? in
                guard let n = FileRules.discNumber(fromFileName: a.discs[0].cueURL?.lastPathComponent ?? "")?.number else { return nil }
                return (n, a)
            }
            if numbered.count == images.count, Set(numbered.map(\.0)).count == numbered.count {
                let discs = numbered.sorted { $0.0 < $1.0 }.map { n, a -> DetectedDisc in var d = a.discs[0]; d.number = n; return d }
                albums = albums.filter { $0.kind != .cueImage } + [DetectedAlbum(url: folder, kind: .cueImage, discs: discs, artworkFiles: artwork)]
            } else {
                for extra in images.dropFirst() {
                    result.issues.append(ScanIssue(url: extra.discs[0].cueURL ?? folder, message: "Another image in the same folder without a disc number in its name; ignored."))
                }
                albums = albums.filter { $0.kind != .cueImage } + [images[0]]
            }
        }
        return albums
    }

    // `folder` holds no audio but has "CD1", "Disc 2"… subfolders that do.
    private func multiDiscAlbum(_ folder: URL, contents: FolderContents, into result: inout ScanResult) -> DetectedAlbum? {
        guard contents.audio.isEmpty, contents.cues.isEmpty else { return nil }
        var discs: [DetectedDisc] = []
        var kinds = Set<AlbumKind>()
        var numbered: [(Int, URL)] = []
        for sub in contents.subfolders {
            if let n = FileRules.discNumber(fromFolderName: sub.lastPathComponent) {
                numbered.append((n, sub))
            }
        }
        guard numbered.count >= 2 || (numbered.count == 1 && contents.subfolders.count == 1) else { return nil }

        for (n, sub) in numbered.sorted(by: { $0.0 < $1.0 }) {
            let subContents = list(sub)
            var scratch = ScanResult()
            let found = albumsInFolder(sub, contents: subContents, into: &scratch)
            result.issues.append(contentsOf: scratch.issues)
            guard found.count == 1, var disc = found[0].discs.first else { return nil }
            disc.number = n
            discs.append(disc)
            kinds.insert(found[0].kind)
        }
        guard !discs.isEmpty else { return nil }

        let kind: AlbumKind = kinds.count == 1 ? kinds.first! : .trackFolder
        let artwork = collectArtwork(folder, contents: contents)
        return DetectedAlbum(url: folder, kind: kind, discs: discs, artworkFiles: artwork)
    }

    private func sacdAlbum(for iso: URL, into result: inout ScanResult) -> DetectedAlbum? {
        guard SACDProbe.isSACD(url: iso) else {
            result.issues.append(ScanIssue(url: iso, message: "ISO is not a SACD image; skipped."))
            return nil
        }
        do {
            let info = try SACDProbe.probe(url: iso)
            let size = (try? iso.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            let folder = iso.deletingLastPathComponent()
            let artwork = collectArtwork(folder, contents: list(folder))
            return DetectedAlbum(
                url: iso,
                kind: .sacdISO,
                discs: [],
                sacd: info,
                isoFile: DetectedTrackFile(url: iso, format: .dsf, fileSize: size),
                artworkFiles: artwork
            )
        } catch {
            result.issues.append(ScanIssue(url: iso, message: "SACD probe failed: \(error.localizedDescription)"))
            return nil
        }
    }

    // Artwork in the folder plus one level of Scans/Artwork/Covers folders.
    private func collectArtwork(_ folder: URL, contents: FolderContents) -> [URL] {
        var files = contents.artwork
        for sub in contents.subfolders where FileRules.artworkFolderNames.contains(sub.lastPathComponent.lowercased()) {
            files.append(contentsOf: list(sub).artwork)
        }
        return files
    }

    private func trackFile(_ url: URL, allowRaw: Bool) -> DetectedTrackFile? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        if let format = AudioFormat.from(url: url) {
            return DetectedTrackFile(url: url, format: format, fileSize: size)
        }
        if allowRaw && FileRules.isRawImage(url) {
            return DetectedTrackFile(url: url, format: .wav, fileSize: size)
        }
        return nil
    }
}

// Pulls artist, title, years, edition, source format and country out of
// folder names such as
//   "1974 - Diamond Dogs (1984, W. Germany, RCA PD83889)"
//   "Linkin Park - 2003 - Meteora 20th Anniversary Edition (MQA)"
//   "Diana Krall- All For You XRCD Japan"
// The bracketed notes are kept verbatim so IdentifyKit can mine them for
// catalog numbers and barcodes.
public enum FolderNameParser {

    // What the folder name says the audio came from.
    public enum SourceHint: String, Sendable, Codable, Hashable, CaseIterable {
        case cd, sacd, vinyl, digital, dvd
    }

    public struct Parsed: Sendable, Equatable {
        public var artist: String?
        public var title: String?          // core title, edition words removed
        public var year: String?           // first year seen: usually the original release
        public var editionYear: String?    // a second year (pressing / remaster)
        public var edition: String?        // "20th Anniversary Edition", "2011 Remaster", …
        public var source: SourceHint?
        public var country: String?        // ISO 3166-1 alpha-2 as MusicBrainz uses it
        public var notes: [String] = []    // bracketed groups, verbatim

        public init() {}

        // Title with the edition kept, for lists and sidebars.
        public var displayTitle: String? {
            guard let title else { return nil }
            guard let edition else { return title }
            return "\(title) (\(edition))"
        }
    }

    public static func parse(_ name: String) -> Parsed {
        var p = Parsed()
        var s = name.replacingOccurrences(of: "_", with: " ")

        // 1. Bracketed notes anywhere in the name.
        for m in s.matches(of: bracketPattern) {
            let note = String(m.1).trimmingCharacters(in: .whitespaces)
            if !note.isEmpty { p.notes.append(note) }
        }
        s = s.replacing(bracketPattern, with: " ")
        s = s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)

        // 2. Years: "1974 - Title", "Artist - 2003 - Title".
        if let m = s.firstMatch(of: #/^\s*((?:19|20)\d{2})\b\s*[-._]?\s*/#) {
            p.year = String(m.1)
            s.removeSubrange(m.range)
        } else if let m = s.firstMatch(of: #/\s+[-–]\s+((?:19|20)\d{2})\s+[-–]\s+/#) {
            p.year = String(m.1)
            s.replaceSubrange(m.range, with: " - ")
        }
        s = trimSeparators(s)

        // 3. "Artist - Title" (also "Artist – Title" and "Artist- Title").
        var parts = s.components(separatedBy: " - ")
        if parts.count == 1 { parts = s.components(separatedBy: " – ") }
        if parts.count == 1, let m = s.firstMatch(of: #/^(.+?\S)-\s+(.+)$/#) { parts = [String(m.1), String(m.2)] }
        var rawTitle: String
        if parts.count >= 2 {
            p.artist = trimSeparators(parts[0])
            rawTitle = parts[1...].joined(separator: " - ")
        } else {
            rawTitle = s
        }
        rawTitle = trimSeparators(rawTitle)

        // 4. A year left at either end of the title ("Aja 1977", "1984" alone stays).
        if p.year == nil, let m = rawTitle.firstMatch(of: #/^((?:19|20)\d{2})\s+(\S.*)$|^(.*\S)\s+((?:19|20)\d{2})$/#) {
            let year = m.1 ?? m.4, rest = m.2 ?? m.3
            if let year, let rest { p.year = String(year); rawTitle = String(rest) }
        }
        if p.year == nil, rawTitle.wholeMatch(of: #/(?:19|20)\d{2}/#) != nil { p.year = rawTitle }

        // 5. Edition / source / country words at the end of the title.
        p.title = refine(title: rawTitle, into: &p)

        // 6. The notes: whole pieces that are edition/source/country words,
        // plus any further years.
        for note in p.notes {
            for piece in note.split(separator: #/\s*[,;/]\s*/#).map(String.init) {
                let leftover = refineNote(piece, into: &p)
                for m in leftover.matches(of: #/\b((?:19|20)\d{2})\b/#) { noteYear(String(m.1), into: &p) }
            }
        }
        if p.artist?.isEmpty == true { p.artist = nil }
        if p.title?.isEmpty == true { p.title = nil }
        return p
    }

    // For an ALBUM tag: "Meteora (20th Anniversary Edition)" → title + edition.
    public static func parseAlbumTitle(_ raw: String) -> Parsed {
        var p = Parsed()
        var s = raw
        for m in s.matches(of: bracketPattern) {
            let note = String(m.1).trimmingCharacters(in: .whitespaces)
            if !note.isEmpty { p.notes.append(note) }
        }
        s = s.replacing(bracketPattern, with: " ")
        s = s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        p.title = refine(title: trimSeparators(s), into: &p)
        for note in p.notes {
            for piece in note.split(separator: #/\s*[,;/]\s*/#).map(String.init) {
                let leftover = refineNote(piece, into: &p)
                for m in leftover.matches(of: #/\b((?:19|20)\d{2})\b/#) { noteYear(String(m.1), into: &p) }
            }
        }
        if p.title?.isEmpty == true { p.title = raw }
        return p
    }

    // MARK: - Vocabulary

    private static var bracketPattern: Regex<(Substring, Substring)> { #/[\(\[\{]([^\)\]\}]*)[\)\]\}]/# }

    private enum Category { case edition, source(SourceHint), country(String), noise }

    private struct Rule {
        let category: Category
        let regex: NSRegularExpression
        let caseSensitive: Bool
    }

    // Each entry: a regex fragment (no anchors) and what it means.
    private static let vocabulary: [(String, Category, Bool)] = [
        // Editions.
        (#"(?:\d{1,3}(?:st|nd|rd|th)\s+)?anniversary(?:\s+(?:super\s+)?deluxe)?(?:\s+(?:edition|version|box\s*set|reissue))?"#, .edition, false),
        (#"(?:super\s+)?deluxe(?:\s+(?:edition|version|box\s*set))?"#, .edition, false),
        (#"(?:19|20)\d{2}\s+(?:remaster(?:ed)?|reissue|mix|remix(?:ed)?|edition|version)"#, .edition, false),
        (#"(?:expanded|special|limited|collector'?s|legacy|definitive|complete|ultimate|premium|extended|remastered|remaster|remixed|reissue|mono|stereo|box\s*set|bonus\s+tracks?|japan\s+edition|import)(?:\s+(?:edition|version))?"#, .edition, false),
        // Physical / digital source.
        (#"xrcd(?:2|24)?|k2\s?hd|shm-?cd|blu-?spec\s?cd2?|hdcd|u?hqcd|gold\s?cd|platinum\s?shm|target\s?cd|mfsl|\d?cds?"#, .source(.cd), false),
        (#"shm-?sacd|sacd(?:-?r)?|dsd(?:64|128|256|512)?|dsf|dff|dst|iso"#, .source(.sacd), false),
        (#"vinyl(?:\s*rip)?|vinylrip|lp|\d{3}\s?g(?:ram)?|12\"|7\"|10\""#, .source(.vinyl), false),
        (#"dvd-?a(?:udio)?|dvd|blu-?ray(?:\s+audio)?|bd-?a|pure\s+audio"#, .source(.dvd), false),
        (#"mqa|web(?:\s*-?\s*(?:flac|dl))?|hi-?res|hires|qobuz|tidal|itunes|bandcamp|hdtracks|digital|(?:16|24|32)\s?-?bits?|(?:16|24|32)[-/](?:44(?:\.1)?|48|88(?:\.2)?|96|176(?:\.4)?|192|352(?:\.8)?|384)(?:\s?khz)?|\d{2,3}(?:\.\d)?\s?khz"#, .source(.digital), false),
        // Containers and rip markers: stripped, mean nothing about the source.
        (#"flac|ape|wav|alac|aiff|wv|tak|m4a|mp3|aac|ogg|lossless|eac|xld|dbpoweramp|cue|log|rip"#, .noise, false),
        // Countries by name (any case) and by code (upper case only).
        (#"(?:japan(?:ese)?)(?:\s+(?:edition|press(?:ing)?|import|release|version))?"#, .country("JP"), false),
        (#"w(?:est)?\.?\s*germany|germany|german|deutschland"#, .country("DE"), false),
        (#"u\.s\.a?\.?|usa|america(?:n)?"#, .country("US"), false),
        (#"u\.k\.|england|british|britain"#, .country("GB"), false),
        (#"europe(?:an)?"#, .country("XE"), false),
        (#"france|french"#, .country("FR"), false),
        (#"italy|italian"#, .country("IT"), false),
        (#"spain|spanish|españa"#, .country("ES"), false),
        (#"holland|netherlands|dutch"#, .country("NL"), false),
        (#"canada|canadian"#, .country("CA"), false),
        (#"australia(?:n)?"#, .country("AU"), false),
        (#"worldwide"#, .country("XW"), false),
        (#"korea(?:n)?"#, .country("KR"), false),
        (#"brazil(?:ian)?"#, .country("BR"), false),
        (#"russia(?:n)?"#, .country("RU"), false),
        (#"sweden|swedish"#, .country("SE"), false),
        (#"norway|norwegian"#, .country("NO"), false),
        (#"denmark|danish"#, .country("DK"), false),
        (#"austria(?:n)?"#, .country("AT"), false),
        (#"switzerland|swiss"#, .country("CH"), false),
        (#"mexico|mexican"#, .country("MX"), false),
        (#"argentina"#, .country("AR"), false),
        (#"taiwan"#, .country("TW"), false),
        (#"hong\s?kong"#, .country("HK"), false),
        (#"china|chinese"#, .country("CN"), false),
        (#"JPN?"#, .country("JP"), true),
        (#"GER"#, .country("DE"), true),
        (#"US"#, .country("US"), true),
        (#"UK"#, .country("GB"), true),
        (#"EU"#, .country("XE"), true),
    ]

    private static let tailRules: [Rule] = vocabulary.map { fragment, category, cs in
        Rule(category: category,
             regex: try! NSRegularExpression(pattern: #"(?:^|(?<=[\s,;/\-]))(?:"# + fragment + #")[\s,;.\-]*$"#, options: cs ? [] : [.caseInsensitive]),
             caseSensitive: cs)
    }

    // Same vocabulary, matched anywhere: for bracketed notes.
    private static let anywhereRules: [Rule] = vocabulary.map { fragment, category, cs in
        Rule(category: category,
             regex: try! NSRegularExpression(pattern: #"(?:^|(?<=[\s,;/\-]))(?:"# + fragment + #")(?=$|[\s,;.\-/])"#, options: cs ? [] : [.caseInsensitive]),
             caseSensitive: cs)
    }

    // Classifies every known word in a note piece; returns what is left
    // (catalog numbers, labels, plain years).
    private static func refineNote(_ piece: String, into p: inout Parsed) -> String {
        var text = piece
        var editions: [String] = []
        var sources: [SourceHint] = []
        for rule in anywhereRules {
            let matches = rule.regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for m in matches.reversed() {
                guard let r = Range(m.range, in: text) else { continue }
                let token = String(text[r])
                switch rule.category {
                case .edition: editions.insert(token, at: 0)
                case .source(let hint): sources.append(hint)
                case .country(let code): if p.country == nil { p.country = code }
                case .noise: break
                }
                text.replaceSubrange(r, with: " ")
            }
        }
        record(editions: editions, sources: sources, into: &p)
        return text.trimmingCharacters(in: .whitespaces)
    }

    private static func record(editions: [String], sources: [SourceHint], into p: inout Parsed) {
        if !editions.isEmpty {
            let joined = editions.joined(separator: ", ")
            p.edition = p.edition.map { $0 + ", " + joined } ?? joined
            // A year inside an edition phrase dates the edition, not the album.
            for m in joined.matches(of: #/\b((?:19|20)\d{2})\b/#) where p.editionYear == nil && String(m.1) != p.year {
                p.editionYear = String(m.1)
            }
        }
        // Prefer the physical medium named over a mere bit depth.
        for hint in [SourceHint.vinyl, .sacd, .dvd, .cd, .digital] where sources.contains(hint) {
            if p.source == nil || (p.source == .digital && hint != .digital) { p.source = hint }
            break
        }
    }

    private static func refine(title raw: String, into p: inout Parsed) -> String {
        var title = trimSeparators(raw)
        var editions: [String] = []
        var sources: [SourceHint] = []
        var changed = true
        var strippedSomething = false
        while changed, !title.isEmpty {
            changed = false
            for rule in tailRules {
                if case .country = rule.category, rule.caseSensitive, !strippedSomething { continue }
                let range = NSRange(title.startIndex..., in: title)
                guard let m = rule.regex.firstMatch(in: title, range: range), let r = Range(m.range, in: title) else { continue }
                let token = trimSeparators(String(title[r]))
                let rest = trimSeparators(String(title[..<r.lowerBound]))
                // Never empty the title: "1984", "LP", "Mono" can be the album.
                if rest.isEmpty { continue }
                switch rule.category {
                case .edition: editions.insert(token, at: 0)
                case .source(let hint): sources.append(hint)
                case .country(let code): if p.country == nil { p.country = code }
                case .noise: break
                }
                title = rest
                changed = true
                strippedSomething = true
                break
            }
        }
        record(editions: editions, sources: sources, into: &p)
        return title
    }

    private static func noteYear(_ year: String, into p: inout Parsed) {
        if p.year == nil { p.year = year }
        else if year != p.year, p.editionYear == nil { p.editionYear = year }
    }

    private static func trimSeparators(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".-–—,;:/")))
    }
}
