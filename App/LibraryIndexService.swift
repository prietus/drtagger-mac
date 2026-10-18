import Foundation
import LibraryKit
import Observation
import ProviderKit
import TagKit

// The library's albums by release, kept on disk between launches and
// refreshed incrementally (unchanged folders are not read again).
@Observable
@MainActor
final class LibraryIndexService {

    private(set) var entries: [String: LibraryIndexEntry] = [:]
    private(set) var root: String?
    private(set) var building = false
    private(set) var progress: String?

    private static var storeURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "drtagger/LibraryIndex.json")
    }

    private struct Stored: Codable { let root: String; let entries: [String: LibraryIndexEntry] }

    init() {
        if let data = try? Data(contentsOf: Self.storeURL), let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            root = stored.root
            entries = stored.entries
        }
    }

    // Builds or refreshes the index of `root`.
    func ensure(root url: URL) async {
        guard !building else { return }
        building = true
        let path = url.standardizedFileURL.path
        let previous = root == path ? entries : [:]
        progress = String(localized: "Indexing the library…")
        let result = await Task.detached(priority: .utility) {
            LibraryIndexer.scan(root: url, previous: previous) { count, folder in
                Task { @MainActor [weak self] in self?.progress = String(localized: "Indexing the library… \(count) folders") }
                _ = folder
            }
        }.value
        entries = result
        root = path
        building = false
        progress = nil
        save()
    }

    // Records the albums written by an Apply so the next ones see them.
    func update(folders: [URL]) async {
        let found: [LibraryIndexEntry] = await Task.detached(priority: .utility) {
            folders.compactMap { folder -> LibraryIndexEntry? in
                let fm = FileManager.default
                let files = (try? fm.contentsOfDirectory(at: folder.onDisk, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                guard let first = files.filter({ TagContainer.from(url: $0) != nil }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first,
                      let tags = try? TaggedFile.readTags(first) else { return nil }
                let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                return LibraryIndexEntry.entry(folder: folder, tags: tags, modified: modified)
            }
        }.value
        for e in found { entries[e.folder] = e }
        save()
    }

    func duplicates(of c: Candidate, excluding folders: Set<String>) -> [LibraryIndexEntry] {
        let key: String? = c.source == .musicbrainz ? "mb:" + c.providerID.lowercased() : c.source == .discogs ? "discogs:" + c.providerID : nil
        return LibraryIndexer.duplicates(in: entries, releaseKey: key, barcode: c.barcode, catalogNumbers: c.catalogNumbers, excluding: folders)
    }

    private func save() {
        guard let root else { return }
        try? FileManager.default.createDirectory(at: Self.storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(Stored(root: root, entries: entries)).write(to: Self.storeURL, options: .atomic)
    }
}
