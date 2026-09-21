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

    private(set) var activeScans = 0
    private(set) var currentFolder: String?
    private(set) var lastScanSummary: String?
    private(set) var sessionIssues: [ScanIssue] = []
    // Roots whose scan has not answered for a while, typically a network
    // volume that stopped responding. The blocked read cannot be cancelled;
    // the app keeps working and the result lands whenever the volume returns.
    private(set) var stalledRoots: [URL] = []
    var selection: PersistentIdentifier?

    var isScanning: Bool { activeScans > 0 }
    static let stallSeconds: Double = 15

    // The container is retained here so the main context it owns stays
    // valid for as long as the controller lives.
    let container: ModelContainer
    private let context: ModelContext

    init(container: ModelContainer) {
        self.container = container
        self.context = container.mainContext
        resetTransientStates()
    }

    // A previous run may have died mid-operation; those states mean
    // nothing after a relaunch.
    private func resetTransientStates() {
        for record in allRecords() where [.scanning, .identifying, .applying].contains(record.state) {
            record.state = .scanned
        }
        try? context.save()
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
        guard !urls.isEmpty else { return }
        activeScans += 1
        defer {
            activeScans -= 1
            if activeScans == 0 { currentFolder = nil }
        }
        let network = urls.filter { VolumeInfo.isNetworkVolume($0) }
        if !network.isEmpty {
            lastScanSummary = String(localized: "Reading from a network volume…")
        }

        let scanner = LibraryScanner()
        let work = Task.detached(priority: .userInitiated) { [self] in
            scanner.scan(urls) { folder in
                Task { @MainActor in
                    self.currentFolder = folder.lastPathComponent
                }
            }
        }
        // Watchdog: report a stall instead of an endless "Scanning…".
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.stallSeconds))
            guard !Task.isCancelled, let self else { return }
            self.stalledRoots.append(contentsOf: urls)
            let name = urls.first?.lastPathComponent ?? ""
            self.lastScanSummary = network.isEmpty
                ? String(localized: "Still reading \(name)… the volume is slow or not responding.")
                : String(localized: "\(name) is on a network volume that is not responding. Check the mount (nfsstat -m) or use a local copy; the app keeps working.")
        }
        let result = await work.value
        watchdog.cancel()
        stalledRoots.removeAll { r in urls.contains(where: { $0.standardizedFileURL == r.standardizedFileURL }) }
        upsert(result)
    }

    // Re-runs detection for one album. States that carry identification
    // progress (needsReview, confident, done…) survive the rescan; only
    // pending / scanning / error collapse to scanned.
    func rescan(_ record: AlbumRecord) async {
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
