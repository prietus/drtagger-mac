import Foundation
import SplitKit

// Moves tagged files into the library layout: root / album folder template
// / "Disc N" for multi-disc releases / "Multichannel" for SACD multichannel
// outputs / track file template. Sidecar files (scans, cue, logs) follow
// when a whole folder moves, and emptied folders are removed.
public enum LibraryOrganizer {

    public struct Options: Sendable, Equatable {
        public var albumFolderTemplate = PathTemplate.defaultAlbumFolder
        public var trackFileTemplate = PathTemplate.defaultTrackFile
        public var asciiFileNames = true
        public var multichannelSubfolder = "Multichannel"
        public init() {}
    }

    public struct Move: Sendable, Equatable, Hashable {
        public let from: URL
        public let to: URL
    }

    public static let sidecarExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "tif", "tiff", "webp", "bmp", "pdf", "cue", "log", "txt", "nfo", "md5", "sfv", "accurip", "m3u", "m3u8", "xml"]

    // Template values from a track's final tags.
    public static func values(from tags: TagSet, fileExtension: String) -> [String: String] {
        let albumArtist = tags.first(TagField.albumArtist) ?? tags.first(TagField.artist) ?? "Unknown Artist"
        let trackTotal = tags.first(TagField.trackTotal).flatMap(Int.init) ?? tags.first(TagField.totalTracks).flatMap(Int.init) ?? 0
        let track = tags.first(TagField.trackNumber).flatMap(Int.init)
        let width = trackTotal >= 100 ? 3 : 2
        return [
            "albumartist": albumArtist,
            "album": tags.first(TagField.album) ?? "Unknown Album",
            "year": String((tags.first(TagField.date) ?? "").prefix(4)),
            "originalyear": tags.first(TagField.originalYear) ?? String((tags.first(TagField.originalDate) ?? tags.first(TagField.date) ?? "").prefix(4)),
            "artist": tags.first(TagField.artist) ?? albumArtist,
            "title": tags.first(TagField.title) ?? "",
            "track": track.map { String(format: "%0\(width)d", $0) } ?? "",
            "tracktotal": trackTotal > 0 ? String(trackTotal) : "",
            "disc": tags.first(TagField.discNumber) ?? "",
            "disctotal": tags.first(TagField.discTotal) ?? tags.first(TagField.totalDiscs) ?? "",
            "label": tags.first(TagField.label) ?? "",
            "catalognumber": tags.first(TagField.catalogNumber) ?? "",
            "media": tags.first(TagField.media) ?? "",
            "ext": fileExtension,
        ]
    }

    public static func target(for url: URL, tags: TagSet, root: URL, options: Options) -> URL {
        let ext = url.pathExtension
        let v = values(from: tags, fileExtension: ext)
        var folder = PathTemplate.render(options.albumFolderTemplate, values: v, ascii: options.asciiFileNames)
        if folder.isEmpty { folder = PathTemplate.sanitizeComponent(v["albumartist"] ?? "Unknown Artist") }
        if let total = Int(v["disctotal"] ?? ""), total > 1, let disc = v["disc"], !disc.isEmpty {
            folder += "/Disc \(disc)"
        }
        if url.deletingLastPathComponent().lastPathComponent == options.multichannelSubfolder {
            folder += "/" + PathTemplate.sanitizeComponent(options.multichannelSubfolder)
        }
        var name = PathTemplate.render(options.trackFileTemplate, values: v, ascii: options.asciiFileNames)
        if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }
        return root.appending(path: folder).appending(path: name).appendingPathExtension(ext)
    }

    // Moves for every file whose target differs from where it is.
    public static func plan(files: [(url: URL, tags: TagSet)], root: URL, options: Options) -> [Move] {
        var used = Set<String>()
        var moves: [Move] = []
        for (url, tags) in files {
            var to = target(for: url, tags: tags, root: root, options: options)
            // Two tracks rendering to the same name (missing titles) get a suffix.
            var n = 2
            while used.contains(to.path.lowercased()) {
                to = to.deletingPathExtension().appendingPathExtension("\(n)").appendingPathExtension(url.pathExtension)
                n += 1
            }
            used.insert(to.path.lowercased())
            if to.standardizedFileURL.path != url.standardizedFileURL.path { moves.append(Move(from: url, to: to)) }
        }
        return moves
    }

    // Performs the moves, then carries the sidecars of every emptied source
    // folder along and removes it. Returns what actually moved (audio and
    // sidecars) so callers can update their records.
    public static func perform(_ moves: [Move]) throws -> [Move] {
        let fm = FileManager.default
        var done: [Move] = []
        for m in moves {
            try fm.createDirectory(at: m.to.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: m.to.path) { throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: m.to.path]) }
            try fm.moveItem(at: m.from, to: m.to)
            done.append(m)
        }
        // Sidecars: per source folder, when it no longer holds audio.
        let sources = Set(done.map { $0.from.deletingLastPathComponent().standardizedFileURL })
        for source in sources {
            guard let items = try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isRegularFileKey], options: []) else { continue }
            let audioLeft = items.contains { TagContainer.from(url: $0) != nil }
            guard !audioLeft, let destination = done.first(where: { $0.from.deletingLastPathComponent().standardizedFileURL == source })?.to.deletingLastPathComponent() else { continue }
            for item in items {
                let name = item.lastPathComponent
                if name.hasPrefix(".") { try? fm.removeItem(at: item); continue }
                guard sidecarExtensions.contains(item.pathExtension.lowercased()) || (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                let to = destination.appending(path: name)
                if fm.fileExists(atPath: to.path) { continue }
                if (try? fm.moveItem(at: item, to: to)) != nil { done.append(Move(from: item, to: to)) }
            }
            if let left = try? fm.contentsOfDirectory(atPath: source.path), left.isEmpty {
                try? fm.removeItem(at: source)
                // Parent folders emptied by this ("Artist/Album/Disc 1").
                var parent = source.deletingLastPathComponent()
                while let rest = try? fm.contentsOfDirectory(atPath: parent.path), rest.filter({ !$0.hasPrefix(".") }).isEmpty, parent.pathComponents.count > 3 {
                    try? fm.removeItem(at: parent)
                    parent = parent.deletingLastPathComponent()
                }
            }
        }
        return done
    }
}
