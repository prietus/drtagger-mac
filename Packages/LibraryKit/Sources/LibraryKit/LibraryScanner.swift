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
        kind == .sacdISO ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
    }

    // Best available title / artist without any network lookup.
    public var titleHint: String? {
        if let t = sacd?.title { return t }
        if let t = discs.first?.cue?.title, !t.isEmpty { return t }
        return FolderNameParser.parse(folderName).title
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

        // Two albums in one folder (two images with CUEs) are legitimate but
        // rare; the caller keeps both, distinguished later by their cue.
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

// Pulls "Artist - Title", a year, and edition noise out of folder names
// like "1974 - Diamond Dogs (1984, W. Germany, RCA PD83889)".
public enum FolderNameParser {

    public struct Parsed: Sendable, Equatable {
        public var artist: String?
        public var title: String?
        public var year: String?
    }

    public static func parse(_ name: String) -> Parsed {
        var parsed = Parsed()
        var s = name

        if let m = s.firstMatch(of: #/\b((?:19|20)\d{2})\b/#) {
            parsed.year = String(m.1)
        }
        // Strip a leading "1974 - " / "1974. " / "(1974) "
        s = s.replacing(#/^\(?(?:19|20)\d{2}\)?\s*[-._]?\s*/#, with: "")
        // Drop trailing parenthesised / bracketed edition notes.
        s = s.replacing(#/\s*[\(\[\{][^\)\]\}]*[\)\]\}]\s*$/#, with: "")
        s = s.trimmingCharacters(in: .whitespaces)

        let parts = s.components(separatedBy: " - ")
        if parts.count >= 2 {
            parsed.artist = parts[0].trimmingCharacters(in: .whitespaces)
            parsed.title = parts[1...].joined(separator: " - ").trimmingCharacters(in: .whitespaces)
        } else if !s.isEmpty {
            parsed.title = s
        }
        return parsed
    }
}
