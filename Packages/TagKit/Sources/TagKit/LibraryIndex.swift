import Foundation

// What the library already holds, one entry per album folder, read from the
// tags of one track per folder (no audio is read). Used to flag releases
// that are already in the library.
public struct LibraryIndexEntry: Sendable, Codable, Equatable, Hashable {
    public let folder: String
    public let releaseIDs: [String]       // "mb:<mbid>", "discogs:<id>"
    public let catalogNumbers: [String]
    public let barcode: String?
    public let artist: String?
    public let album: String?
    public let modified: Date

    public init(folder: String, releaseIDs: [String], catalogNumbers: [String], barcode: String?, artist: String?, album: String?, modified: Date) {
        self.folder = folder; self.releaseIDs = releaseIDs; self.catalogNumbers = catalogNumbers
        self.barcode = barcode; self.artist = artist; self.album = album; self.modified = modified
    }

    public static func entry(folder: URL, tags: TagSet, modified: Date) -> LibraryIndexEntry {
        var ids: [String] = []
        if let mb = tags.first(TagField.mbAlbumID)?.lowercased(), !mb.isEmpty { ids.append("mb:" + mb) }
        if let d = tags.first(TagField.discogsReleaseID), !d.isEmpty { ids.append("discogs:" + d) }
        return LibraryIndexEntry(folder: folder.standardizedFileURL.path, releaseIDs: ids, catalogNumbers: tags[TagField.catalogNumber],
                                 barcode: tags.first(TagField.barcode)?.filter(\.isNumber), artist: tags.first(TagField.albumArtist) ?? tags.first(TagField.artist),
                                 album: tags.first(TagField.album), modified: modified)
    }
}

public enum LibraryIndexer {

    static let audioExtensions: Set<String> = ["flac", "dsf", "dff", "wav", "aif", "aiff", "ape", "wv", "tta", "m4a"]

    // Walks `root`; folders unchanged since `previous` (same modification
    // date) are reused without reading anything.
    public static func scan(root: URL, previous: [String: LibraryIndexEntry] = [:], progress: @Sendable (Int, String) -> Void = { _, _ in }) -> [String: LibraryIndexEntry] {
        let fm = FileManager.default
        var result: [String: LibraryIndexEntry] = [:]
        var visited = 0
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [:] }
        var folders: [URL] = [root]
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            folders.append(url)
        }
        for folder in folders {
            visited += 1
            let path = folder.standardizedFileURL.path
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if let old = previous[path], old.modified == modified {
                result[path] = old
                continue
            }
            guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            let audio = files.filter { audioExtensions.contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard let first = audio.first, let tags = try? TaggedFile.readTags(first) else { continue }
            result[path] = .entry(folder: folder, tags: tags, modified: modified)
            if visited % 25 == 0 { progress(visited, folder.lastPathComponent) }
        }
        progress(visited, "")
        return result
    }

    // Entries holding the same release, outside `excluding` folders: by
    // release ID, else by barcode plus catalog number.
    public static func duplicates(in index: [String: LibraryIndexEntry], releaseKey: String?, barcode: String?, catalogNumbers: [String], excluding: Set<String>) -> [LibraryIndexEntry] {
        let normalize: (String) -> String = { $0.uppercased().filter { $0.isLetter || $0.isNumber } }
        let cats = Set(catalogNumbers.map(normalize).filter { !$0.isEmpty })
        let code = barcode?.filter(\.isNumber)
        return index.values.filter { e in
            guard !excluding.contains(e.folder) else { return false }
            if let key = releaseKey, e.releaseIDs.contains(key) { return true }
            if e.releaseIDs.isEmpty || releaseKey == nil, let code, !code.isEmpty, e.barcode == code,
               !cats.isEmpty, e.catalogNumbers.contains(where: { cats.contains(normalize($0)) }) { return true }
            return false
        }.sorted { $0.folder < $1.folder }
    }
}
