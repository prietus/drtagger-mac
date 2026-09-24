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

    // Adds folders opened from another app and selects the album that was
    // asked for, even if something else was selected before.
    func open(_ urls: [URL]) async {
        await addRoots(urls)
        let paths = urls.map(\.standardizedFileURL.path)
        if let record = allRecords().first(where: { record in
            paths.contains { record.path == $0 || record.path.hasPrefix($0 + "/") }
        }) {
            selection = record.persistentModelID
        }
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
        autoGroup(result.albums.compactMap { fetch(path: $0.id) })
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

    // MARK: Release sets

    // Records that are one release together with `record`, in disc order.
    func members(of record: AlbumRecord) -> [AlbumRecord] {
        guard let id = record.setID else { return [record] }
        return allRecords().filter { $0.setID == id }.sorted { ($0.setPosition ?? 0, $0.addedAt) < ($1.setPosition ?? 0, $1.addedAt) }
    }

    func isLeader(_ record: AlbumRecord) -> Bool {
        members(of: record).first?.path == record.path
    }

    // Records in the same folder that carry a disc number and are not yet
    // in a set: what "Group with folder siblings" would join.
    func siblingCandidates(of record: AlbumRecord) -> [AlbumRecord] {
        guard let key = setKey(record) else { return [] }
        return allRecords().filter { $0.path != record.path && $0.setID == nil && setKey($0) == key }
    }

    // What makes two records discs of one release. SACDs carry the box title
    // and catalog in their master TOC, so their key ignores folders; other
    // albums need the same parent folder and the same name minus its disc
    // token ("Box Set (Disc 1)" / "Box Set (Disc 2)").
    private func setKey(_ record: AlbumRecord) -> String? {
        guard let detected = record.detected, detected.discPosition != nil else { return nil }
        if let sacd = detected.sacd, sacd.albumSetSize > 1 {
            // The album catalog (often the box barcode) is shared by every
            // disc; titles may carry "Disc N of M", so they come second.
            let catalog = sacd.albumCatalogNumber.lowercased().trimmingCharacters(in: .whitespaces)
            if !catalog.isEmpty { return "sacd|cat|\(catalog)|\(sacd.albumSetSize)" }
            let title = detected.setBaseName.lowercased().trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { return "sacd|title|\(title)|\(sacd.albumSetSize)" }
        }
        return "name|" + record.url.deletingLastPathComponent().path + "|" + detected.setBaseName.lowercased()
    }

    // Evidence-based grouping after a scan. New records join a set that
    // already exists in the queue (an ISO added later still finds its box)
    // or form one with ungrouped peers; a lone "disc 2 of 3" becomes a set
    // of one so the missing discs are visible.
    private func autoGroup(_ records: [AlbumRecord]) {
        let all = allRecords()
        // A set of one (a lone "disc 2 of 4") is still open to its siblings.
        func loose(_ r: AlbumRecord) -> Bool { r.setID == nil || members(of: r).count == 1 }
        for r in records where loose(r) {
            guard let key = setKey(r) else { continue }
            let peers = all.filter { $0.path != r.path && setKey($0) == key }
            let mine = r.detected?.discPosition?.number
            if let existing = peers.first(where: { !loose($0) }) {
                let taken = members(of: existing).compactMap(\.setPosition)
                if let mine, taken.contains(mine) { continue }        // same disc twice: leave it alone
                join(r, to: existing)
            } else {
                let group = [r] + peers.filter { loose($0) }
                if group.count > 1, group.contains(where: { $0.setID != nil }) {
                    for g in group { g.setID = nil }
                }
                let declared = group.compactMap { $0.detected?.discPosition?.total }.max()
                guard group.count > 1 || (declared ?? 0) > 1 else { continue }
                let positions = group.compactMap { $0.detected?.discPosition?.number }
                guard Set(positions).count == positions.count else { continue }
                assign(group)
            }
        }
    }

    private func join(_ record: AlbumRecord, to existing: AlbumRecord) {
        record.setID = existing.setID
        record.setTitle = existing.setTitle
        let all = members(of: existing)
        record.setPosition = record.detected?.discPosition?.number ?? ((all.compactMap(\.setPosition).max() ?? 0) + 1)
        let declared = all.compactMap { $0.detected?.discPosition?.total }.max() ?? 0
        let total = max(declared, all.compactMap(\.setPosition).max() ?? 0, all.count)
        for m in all { m.setTotal = total }
        resetIdentification(all)
    }

    // A set that changed shape needs a fresh identification: the stored one
    // was for other discs.
    private func resetIdentification(_ records: [AlbumRecord]) {
        for r in records where r.identificationData != nil {
            r.identificationData = nil
            r.selectedCandidateID = nil
            if [.confident, .needsReview].contains(r.state) { r.state = .scanned }
        }
    }

    func group(_ records: [AlbumRecord]) {
        guard records.count > 1 else { return }
        assign(records)
        resetIdentification(records)
        try? context.save()
    }

    private func assign(_ records: [AlbumRecord]) {
        let id = UUID().uuidString
        let ordered = records.sorted { a, b in
            let pa = a.detected?.discPosition?.number ?? Int.max, pb = b.detected?.discPosition?.number ?? Int.max
            return pa != pb ? pa < pb : a.displayTitle.localizedStandardCompare(b.displayTitle) == .orderedAscending
        }
        let declared = ordered.compactMap { $0.detected?.discPosition?.total }.max()
        let total = max(declared ?? 0, ordered.compactMap { $0.detected?.discPosition?.number }.max() ?? 0, ordered.count)
        let title = ordered.first?.detected?.setBaseName ?? ordered.first?.displayTitle ?? ""
        for (i, r) in ordered.enumerated() {
            r.setID = id
            r.setPosition = r.detected?.discPosition?.number ?? (i + 1)
            r.setTotal = total
            r.setTitle = title
        }
    }

    func ungroup(_ record: AlbumRecord) {
        let all = members(of: record)
        for r in all {
            r.setID = nil; r.setPosition = nil; r.setTotal = nil; r.setTitle = nil
        }
        resetIdentification(all)
        try? context.save()
    }

    func setPosition(_ record: AlbumRecord, to position: Int) {
        guard position >= 1 else { return }
        record.setPosition = position
        let all = members(of: record)
        let total = max(all.compactMap(\.setPosition).max() ?? 0, all.first?.setTotal ?? 0)
        for r in all { r.setTotal = total }
        try? context.save()
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
