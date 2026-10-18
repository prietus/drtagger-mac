import Foundation
import IdentifyKit
import LibraryKit
import ProviderKit
import SACDKit
import SplitKit
import SwiftData
import TagKit

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
    // Phase 2: disc identity and split results (JSON, optional so older
    // stores migrate automatically).
    var tocData: Data?
    var ctdbData: Data?
    var splitOutcomeData: Data?
    var sacdOutcomeData: Data?
    // Phase 4: identification result and the user's pick.
    var identificationData: Data?
    var selectedCandidateID: String?
    // Phase 5: tag locks, the original metadata of every written file, the
    // write reports and the artwork choice.
    var tagLocksData: Data?
    var tagBackupsData: Data?
    var tagReportsData: Data?
    var taggedAt: Date?
    var coverOptionID: String?
    // Phase 6: where the organizer moved files (old path → new path).
    var fileMovesData: Data?
    // Phase 7: release sets (several records that are one multi-disc release).
    var setID: String?
    var setPosition: Int?
    var setTotal: Int?
    var setTitle: String?
    // Phase 8: bulk mode.
    var batchStatusRaw: String?
    var batchNote: String?

    init(detected: DetectedAlbum, issues: [ScanIssue] = [], addedAt: Date = Date()) {
        path = detected.id
        kindRaw = detected.kind.rawValue
        stateRaw = AlbumState.scanned.rawValue
        displayTitle = ""
        discCount = 0
        trackCount = 0
        formatsRaw = ""
        hasDST = false
        hasMultichannel = false
        let now = addedAt
        self.addedAt = now
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

    var url: URL { URL(fileURLWithPath: path).onDisk }

    // Decoded once per change of the stored JSON: the sidebar, the batch
    // and the table read these for hundreds of albums on every redraw.
    @Transient private var detectedCache: (data: Data, value: DetectedAlbum?)? = nil
    @Transient private var identificationCache: (data: Data, value: IdentificationResult?)? = nil

    var detected: DetectedAlbum? {
        guard let detailsData else { return nil }
        if let c = detectedCache, c.data == detailsData { return c.value }
        let value = (try? JSONDecoder().decode(DetectedAlbum.self, from: detailsData))?.onDisk()
        detectedCache = (detailsData, value)
        return value
    }

    var issues: [ScanIssue] {
        guard let issuesData else { return [] }
        return (try? JSONDecoder().decode([ScanIssue].self, from: issuesData)) ?? []
    }

    var formats: [AudioFormat] {
        formatsRaw.split(separator: ",").compactMap { AudioFormat(rawValue: String($0)) }
    }

    // Has a CUE, so a disc TOC and a CUETools DB check make sense.
    var hasCueSheet: Bool { kind == .cueImage || kind == .cueMultiFile }
    // One image file per disc: splitting produces the tracks. Albums that
    // already are one file per track have nothing to split.
    var isSplittable: Bool { kind == .cueImage }

    var toc: DiscTOC? {
        get { tocData.flatMap { try? JSONDecoder().decode(DiscTOC.self, from: $0) } }
        set { tocData = newValue.flatMap { try? JSONEncoder().encode($0) }; updatedAt = Date() }
    }

    var ctdbReport: CTDBReport? {
        get { ctdbData.flatMap { try? JSONDecoder().decode(CTDBReport.self, from: $0) } }
        set { ctdbData = newValue.flatMap { try? JSONEncoder().encode($0) }; updatedAt = Date() }
    }

    // One outcome per split disc (stores written before phase 7 hold a single object).
    var splitOutcomes: [SplitOutcome] {
        get {
            guard let data = splitOutcomeData else { return [] }
            if let list = try? JSONDecoder().decode([SplitOutcome].self, from: data) { return list }
            return (try? JSONDecoder().decode(SplitOutcome.self, from: data)).map { [$0] } ?? []
        }
        set { splitOutcomeData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue); updatedAt = Date() }
    }

    var splitOutcome: SplitOutcome? { splitOutcomes.first }

    // The disc position this record's files cover: its set position, else
    // the "disc 2 of 3" evidence in its own name, else 1.
    var discPosition: Int { setPosition ?? detected?.discPosition?.number ?? 1 }

    var identification: IdentificationResult? {
        get {
            guard let data = identificationData else { return nil }
            if let c = identificationCache, c.data == data { return c.value }
            let value = try? JSONDecoder().decode(IdentificationResult.self, from: data)
            identificationCache = (data, value)
            return value
        }
        set {
            identificationData = newValue.flatMap { try? JSONEncoder().encode($0) }
            identificationCache = identificationData.map { ($0, newValue) }
            updatedAt = Date()
        }
    }

    var selectedCandidate: ScoredCandidate? {
        guard let id = selectedCandidateID else { return nil }
        return identification?.candidates.first { $0.id == id }
    }

    var batchStatus: BatchStatus? {
        get { batchStatusRaw.flatMap(BatchStatus.init(rawValue:)) }
        set { batchStatusRaw = newValue?.rawValue }
    }

    var fileMoves: [String: String] {
        get { fileMovesData.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:] }
        set { fileMovesData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue); updatedAt = Date() }
    }

    // Follows recorded moves so stored URLs still point at the files.
    func resolved(_ url: URL) -> URL {
        let moves = fileMoves
        var path = url.path
        var hops = 0
        while let next = moves[path], hops < 8 { path = next; hops += 1 }
        return (path == url.path ? url : URL(fileURLWithPath: path)).onDisk
    }

    var tagLocks: Set<String> {
        get { tagLocksData.flatMap { try? JSONDecoder().decode(Set<String>.self, from: $0) } ?? [] }
        set { tagLocksData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue); updatedAt = Date() }
    }

    // Original metadata of every file written by Apply; kept until Restore.
    var tagBackups: [TagBackup] {
        get { tagBackupsData.flatMap { try? JSONDecoder().decode([TagBackup].self, from: $0) } ?? [] }
        set { tagBackupsData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue); updatedAt = Date() }
    }

    var tagReports: [TagWriteReport] {
        get { tagReportsData.flatMap { try? JSONDecoder().decode([TagWriteReport].self, from: $0) } ?? [] }
        set { tagReportsData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue); updatedAt = Date() }
    }

    // One outcome per extracted area (stereo, multichannel).
    var sacdOutcomes: [SACDExtractOutcome] {
        get { sacdOutcomeData.flatMap { try? JSONDecoder().decode([SACDExtractOutcome].self, from: $0) } ?? [] }
        set { sacdOutcomeData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue); updatedAt = Date() }
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

// What we keep from a CUETools DB lookup: the entries' confidence, the
// MusicBrainz / FreeDB candidates it lists for the TOC, and, once the disc
// has been split, how our CRCs compared.
struct CTDBReport: Codable, Equatable, Sendable {
    var checkedAt: Date
    var entryCount: Int
    var totalConfidence: Int
    var bestConfidence: Int
    var metadata: [CUEToolsDBClient.Metadata]
    var verification: CUEToolsDBClient.Verification?

    var isKnownDisc: Bool { entryCount > 0 }
}
