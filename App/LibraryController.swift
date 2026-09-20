import AppKit
import Foundation
import LibraryKit
import Observation
import SwiftData

// Drives album discovery: takes dropped or chosen folders, runs
// LibraryScanner off the main actor and upserts AlbumRecords into the
// SwiftData store. All persistence happens on the main context.
@Observable
@MainActor
final class LibraryController {

    private(set) var isScanning = false
    private(set) var currentFolder: String?
    private(set) var lastScanSummary: String?
    private(set) var sessionIssues: [ScanIssue] = []
    var selection: PersistentIdentifier?

    // The container is retained here so the main context it owns stays
    // valid for as long as the controller lives.
    let container: ModelContainer
    private let context: ModelContext

    init(container: ModelContainer) {
        self.container = container
        self.context = container.mainContext
    }

    // MARK: Adding

    func presentAddPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.allowedContentTypes = []
        panel.message = String(localized: "Choose folders with SACD ISOs, CD images + CUE, or album tracks.")
        panel.prompt = String(localized: "Add")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        Task { await self.addRoots(urls) }
    }

    // Scans the given roots and stores every album found. Existing records
    // (same path) are refreshed instead of duplicated.
    func addRoots(_ urls: [URL]) async {
        guard !urls.isEmpty, !isScanning else { return }
        isScanning = true
        currentFolder = nil
        defer {
            isScanning = false
            currentFolder = nil
        }

        let scanner = LibraryScanner()
        let result = await Task.detached(priority: .userInitiated) { [self] in
            scanner.scan(urls) { folder in
                Task { @MainActor in
                    self.currentFolder = folder.lastPathComponent
                }
            }
        }.value

        upsert(result)
    }

    // Re-runs detection for one album. States that carry identification
    // progress (needsReview, confident, done…) survive the rescan; only
    // pending / scanning / error collapse to scanned.
    func rescan(_ record: AlbumRecord) async {
        guard !isScanning else { return }
        let url = record.url
        let previous = record.state
        record.state = .scanning
        await addRoots([url])
        if record.state == .scanning {
            record.state = .error
            record.errorMessage = String(localized: "The album is no longer detected at this path.")
        } else if ![.pending, .scanning, .error].contains(previous) {
            record.state = previous
        }
        try? context.save()
    }

    // `drtagger --add <path> [<path>…]` scans the given paths at launch.
    // Used by tests and scripts to load a library without the open panel.
    func importLaunchArguments(_ arguments: [String] = CommandLine.arguments) async {
        guard let index = arguments.firstIndex(of: "--add") else { return }
        let paths = arguments[(index + 1)...].prefix { !$0.hasPrefix("--") }
        let urls = paths.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
        await addRoots(Array(urls))
    }

    private func upsert(_ result: ScanResult) {
        var added = 0
        var updated = 0
        for album in result.albums {
            let issues = issues(in: result, for: album)
            if let existing = fetch(path: album.id) {
                existing.apply(detected: album, issues: issues)
                if [.pending, .scanning, .error].contains(existing.state) {
                    existing.state = .scanned
                }
                updated += 1
            } else {
                context.insert(AlbumRecord(detected: album, issues: issues))
                added += 1
            }
        }
        sessionIssues = result.issues
        try? context.save()

        lastScanSummary = String(localized: "\(added) added, \(updated) updated, \(result.foldersVisited) folders scanned")
        if selection == nil, let first = result.albums.first, let record = fetch(path: first.id) {
            selection = record.persistentModelID
        }
    }

    // Issues raised inside this album's folder (or next to the ISO).
    private func issues(in result: ScanResult, for album: DetectedAlbum) -> [ScanIssue] {
        let folder = album.kind == .sacdISO ? album.url.deletingLastPathComponent() : album.url
        let prefix = folder.standardizedFileURL.path
        return result.issues.filter { $0.url.standardizedFileURL.path.hasPrefix(prefix) }
    }

    // MARK: Queries

    func fetch(path: String) -> AlbumRecord? {
        var descriptor = FetchDescriptor<AlbumRecord>(predicate: #Predicate { $0.path == path })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    func record(id: PersistentIdentifier?) -> AlbumRecord? {
        guard let id else { return nil }
        return context.model(for: id) as? AlbumRecord
    }

    func allRecords() -> [AlbumRecord] {
        let descriptor = FetchDescriptor<AlbumRecord>(sortBy: [SortDescriptor(\.addedAt)])
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: Removing

    func remove(_ records: [AlbumRecord]) {
        for record in records {
            if selection == record.persistentModelID {
                selection = nil
            }
            context.delete(record)
        }
        try? context.save()
    }

    func removeAll() {
        remove(allRecords())
    }
}
