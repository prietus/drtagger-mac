import Foundation
import LibraryKit
import SwiftData

// One album in the queue, persisted across launches. The scanner's full
// DetectedAlbum is kept as JSON so the inspector can show discs, tracks,
// CUE and SACD details without rescanning; the scalar columns exist for
// sorting, filtering and the sidebar row.
@Model
final class AlbumRecord {
    @Attribute(.unique) var path: String     // album folder or ISO file
    var kindRaw: String
    var stateRaw: String
    var displayTitle: String
    var artistHint: String?
    var yearHint: String?
    var discCount: Int
    var trackCount: Int
    var formatsRaw: String                   // "flac,dsf"
    var hasDST: Bool
    var hasMultichannel: Bool
    var detailsData: Data?
    var issuesData: Data?
    var errorMessage: String?
    var addedAt: Date
    var updatedAt: Date

    init(detected: DetectedAlbum, issues: [ScanIssue] = []) {
        path = detected.id
        kindRaw = detected.kind.rawValue
        stateRaw = AlbumState.scanned.rawValue
        displayTitle = ""
        discCount = 0
        trackCount = 0
        formatsRaw = ""
        hasDST = false
        hasMultichannel = false
        let now = Date()
        addedAt = now
        updatedAt = now
        apply(detected: detected, issues: issues)
    }

    func apply(detected: DetectedAlbum, issues: [ScanIssue]) {
        kindRaw = detected.kind.rawValue
        displayTitle = detected.titleHint ?? detected.folderName
        artistHint = detected.artistHint
        yearHint = detected.yearHint
        discCount = detected.kind == .sacdISO ? 1 : max(1, detected.discs.count)
        trackCount = detected.trackCount
        formatsRaw = detected.formats.map(\.rawValue).sorted().joined(separator: ",")
        hasDST = detected.sacd?.hasDST ?? false
        hasMultichannel = detected.sacd?.multichannelArea != nil
        detailsData = try? JSONEncoder().encode(detected)
        issuesData = try? JSONEncoder().encode(issues)
        errorMessage = nil
        updatedAt = Date()
    }

    var kind: AlbumKind { AlbumKind(rawValue: kindRaw) ?? .trackFolder }

    var state: AlbumState {
        get { AlbumState(rawValue: stateRaw) ?? .pending }
        set { stateRaw = newValue.rawValue; updatedAt = Date() }
    }

    var url: URL { URL(fileURLWithPath: path) }

    var detected: DetectedAlbum? {
        guard let detailsData else { return nil }
        return try? JSONDecoder().decode(DetectedAlbum.self, from: detailsData)
    }

    var issues: [ScanIssue] {
        guard let issuesData else { return [] }
        return (try? JSONDecoder().decode([ScanIssue].self, from: issuesData)) ?? []
    }

    var formats: [AudioFormat] {
        formatsRaw.split(separator: ",").compactMap { AudioFormat(rawValue: String($0)) }
    }

    var subtitle: String {
        var parts: [String] = [kind.displayName]
        if trackCount > 0 {
            parts.append(trackCount == 1 ? String(localized: "1 track") : String(localized: "\(trackCount) tracks"))
        }
        if discCount > 1 {
            parts.append(String(localized: "\(discCount) discs"))
        }
        if kind == .sacdISO {
            if hasDST { parts.append("DST") }
            if hasMultichannel { parts.append(String(localized: "multichannel")) }
        } else if !formats.isEmpty {
            parts.append(formats.map(\.displayName).joined(separator: "/"))
        }
        return parts.joined(separator: " · ")
    }
}
