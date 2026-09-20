import AppKit
import Foundation
import Observation

// Processing state of one album in the queue. Phase 1 wires the scanner
// and identifier that drive these transitions; for now entries stay
// `pending`.
enum AlbumState: Equatable, Sendable {
    case pending
    case scanning
    case identifying
    case confident
    case needsReview
    case applying
    case done
    case error(String)

    var label: String {
        switch self {
        case .pending: return String(localized: "Pending")
        case .scanning: return String(localized: "Scanning")
        case .identifying: return String(localized: "Identifying")
        case .confident: return String(localized: "Confident match")
        case .needsReview: return String(localized: "Needs review")
        case .applying: return String(localized: "Applying")
        case .done: return String(localized: "Done")
        case .error: return String(localized: "Error")
        }
    }

    var systemImage: String {
        switch self {
        case .pending: return "clock"
        case .scanning: return "magnifyingglass"
        case .identifying: return "waveform.badge.magnifyingglass"
        case .confident: return "checkmark.seal"
        case .needsReview: return "questionmark.circle"
        case .applying: return "pencil.and.outline"
        case .done: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle"
        }
    }
}

struct QueuedAlbum: Identifiable, Equatable, Sendable {
    let id: UUID
    let url: URL
    var state: AlbumState
    let addedAt: Date

    var displayName: String { url.lastPathComponent }
}

@Observable
@MainActor
final class AlbumQueue {

    private(set) var albums: [QueuedAlbum] = []
    var selection: QueuedAlbum.ID?

    // File extensions that can stand alone as an album source (an image
    // file dropped without its folder). Folders are always accepted.
    nonisolated static let standaloneExtensions: Set<String> = ["iso", "cue"]

    // Adds folders (and standalone image files) to the queue, ignoring
    // duplicates by standardized path. Returns the entries that were added.
    @discardableResult
    func add(urls: [URL]) -> [QueuedAlbum] {
        var added: [QueuedAlbum] = []
        let existing = Set(albums.map { $0.url.standardizedFileURL.path })
        var seen = existing
        for url in urls {
            let std = url.standardizedFileURL
            guard Self.isAcceptable(std) else { continue }
            guard seen.insert(std.path).inserted else { continue }
            let album = QueuedAlbum(id: UUID(), url: std, state: .pending, addedAt: Date())
            albums.append(album)
            added.append(album)
        }
        if selection == nil, let first = added.first {
            selection = first.id
        }
        return added
    }

    func remove(ids: Set<QueuedAlbum.ID>) {
        albums.removeAll { ids.contains($0.id) }
        if let sel = selection, ids.contains(sel) {
            selection = albums.first?.id
        }
    }

    func clear() {
        albums.removeAll()
        selection = nil
    }

    func album(id: QueuedAlbum.ID?) -> QueuedAlbum? {
        guard let id else { return nil }
        return albums.first { $0.id == id }
    }

    func presentAddPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.message = String(localized: "Choose folders with SACD ISOs, CD images + CUE, or album tracks.")
        panel.prompt = String(localized: "Add")
        if panel.runModal() == .OK {
            add(urls: panel.urls)
        }
    }

    nonisolated static func isAcceptable(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
        if isDir.boolValue { return true }
        return standaloneExtensions.contains(url.pathExtension.lowercased())
    }
}
