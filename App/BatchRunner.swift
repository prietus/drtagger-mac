import Foundation
import IdentifyKit
import LibraryKit
import Observation
import ProviderKit
import TagKit

// Where an album is in a batch. Persisted on the record so a batch resumes
// after quitting the app.
enum BatchStatus: String, Codable, CaseIterable {
    case pending          // not started
    case readyToIdentify  // SACD extracted, fingerprints possible
    case readyToFinish    // confident match: files (if needed), tags, organise
    case working          // a worker has it right now
    case review           // set aside: not sure, or something to look at
    case done
    case failed

    var isOpen: Bool { [.pending, .readyToIdentify, .readyToFinish, .working].contains(self) }
}

// Runs the queue unattended, beets-style. Two workers share the albums:
// the network one identifies (one album at a time, so MusicBrainz, AcoustID
// and Discogs rate limits hold), the CPU one extracts / splits and writes
// tags. Albums without a sure match are set aside for review and the batch
// goes on.
@Observable
@MainActor
final class BatchRunner {

    enum Mode: String, CaseIterable, Identifiable {
        case importToLibrary   // organise into the library after tagging
        case updateInPlace     // tags only, files stay where they are
        var id: String { rawValue }
    }

    private(set) var isRunning = false
    private(set) var stopping = false
    // Preview run: identify and classify every album, write nothing.
    var dryRun: Bool {
        get { UserDefaults.standard.bool(forKey: "batch.dryRun") }
        set { UserDefaults.standard.set(newValue, forKey: "batch.dryRun") }
    }
    private(set) var startedAt: Date?
    private(set) var finishedAtStart = 0
    private(set) var indexing: String?
    private(set) var networkActivity: String?
    private(set) var cpuActivity: String?
    var mode: Mode {
        get { Mode(rawValue: UserDefaults.standard.string(forKey: "batch.mode") ?? "") ?? .importToLibrary }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "batch.mode") }
    }

    private weak var library: LibraryController?
    private weak var identify: IdentifyService?
    private weak var disc: DiscService?
    private weak var tagging: TagService?
    private weak var settings: AppSettings?
    private weak var index: LibraryIndexService?

    func attach(library: LibraryController, identify: IdentifyService, disc: DiscService, tagging: TagService, settings: AppSettings, index: LibraryIndexService) {
        self.library = library; self.identify = identify; self.disc = disc; self.tagging = tagging; self.settings = settings; self.index = index
    }

    // Albums still to go and the pace so far: an estimate of the time left.
    func estimatedRemaining(open: Int, finished: Int) -> TimeInterval? {
        guard isRunning, let startedAt, finished > finishedAtStart, open > 0 else { return nil }
        let rate = Double(finished - finishedAtStart) / Date().timeIntervalSince(startedAt)
        return rate > 0 ? Double(open) / rate : nil
    }

    // MARK: Control

    // Marks every unfinished album of the queue and starts the workers.
    func start(mode: Mode, dryRun: Bool) {
        guard !isRunning, let library else { return }
        self.mode = mode
        self.dryRun = dryRun
        // Every album not written by an earlier batch starts over (a
        // preview run before a real one, failures, earlier reviews).
        for r in library.allRecords() {
            if r.taggedAt != nil, r.batchStatus == .done { continue }
            set([r], .pending, note: nil)
        }
        save()
        run()
    }

    func resume() {
        guard !isRunning else { return }
        run()
    }

    // Finishes the albums in progress, leaves the rest pending.
    func stop() {
        guard isRunning else { return }
        stopping = true
    }

    // Leaves the batch: statuses are cleared, the albums stay in the queue.
    func clear() {
        guard !isRunning, let library else { return }
        for r in library.allRecords() { r.batchStatusRaw = nil; r.batchNote = nil }
        save()
    }

    private func run() {
        isRunning = true
        stopping = false
        startedAt = Date()
        finishedAtStart = library.map { BatchCounts($0.allRecords()).finished } ?? 0
        Task {
            // Duplicates are looked up in the library index.
            if let root = settings?.libraryRootURL, let index {
                indexing = String(localized: "Indexing the library…")
                await index.ensure(root: root)
                indexing = nil
            }
            async let network: Void = networkWorker()
            async let cpu: Void = cpuWorker()
            _ = await (network, cpu)
            isRunning = false
            stopping = false
            networkActivity = nil
            cpuActivity = nil
            save()
        }
    }

    // MARK: Workers

    private func networkWorker() async {
        while !stopping {
            guard let r = next(where: { r, members in
                r.batchStatus == .readyToIdentify || (r.batchStatus == .pending && !self.extractFirst(r, members))
            }) else {
                if hasWork(for: .network) { try? await Task.sleep(for: .milliseconds(500)); continue }
                return
            }
            await identifyStep(r)
        }
    }

    private func cpuWorker() async {
        while !stopping {
            guard let r = next(where: { r, members in
                r.batchStatus == .readyToFinish || (r.batchStatus == .pending && self.extractFirst(r, members))
            }) else {
                if hasWork(for: .cpu) { try? await Task.sleep(for: .milliseconds(500)); continue }
                return
            }
            if r.batchStatus == .pending { await extractStep(r) } else { await finishStep(r) }
        }
    }

    private enum Worker { case network, cpu }

    // Something the other worker may still hand over.
    private func hasWork(for worker: Worker) -> Bool {
        guard let library else { return false }
        return library.allRecords().contains { r in
            guard let s = r.batchStatus else { return false }
            switch worker {
            case .network: return s == .working || s == .readyToFinish || s == .pending
            case .cpu: return s == .working || s == .readyToIdentify || s == .pending
            }
        }
    }

    // SACD images are extracted before they are identified (fingerprints).
    private func extractFirst(_ r: AlbumRecord, _ members: [AlbumRecord]) -> Bool {
        !dryRun && mode == .importToLibrary && r.kind == .sacdISO && members.contains(where: Workflow.needsFiles)
    }

    private func next(where pick: (AlbumRecord, [AlbumRecord]) -> Bool) -> AlbumRecord? {
        guard let library else { return nil }
        for r in library.allRecords().sorted(by: Self.queueOrder) where library.isLeader(r) {
            if pick(r, library.members(of: r)) { return r }
        }
        return nil
    }

    // The sidebar's order: newest scan first, then by title.
    static func queueOrder(_ a: AlbumRecord, _ b: AlbumRecord) -> Bool {
        a.addedAt != b.addedAt ? a.addedAt > b.addedAt : a.displayTitle.localizedStandardCompare(b.displayTitle) == .orderedAscending
    }

    // MARK: Steps

    private func extractStep(_ r: AlbumRecord) async {
        guard let library, let disc, let settings else { return }
        let members = library.members(of: r)
        set(members, .working, note: String(localized: "Extracting"))
        cpuActivity = String(localized: "Extracting \(r.displayTitle)")
        let ok = await Workflow.produceFiles(members, disc: disc, settings: settings)
        cpuActivity = nil
        set(members, ok ? .readyToIdentify : .failed, note: ok ? nil : (r.errorMessage ?? String(localized: "Extraction failed")))
        save()
    }

    private func identifyStep(_ r: AlbumRecord) async {
        guard let library, let identify, let settings else { return }
        let members = library.members(of: r)
        set(members, .working, note: String(localized: "Identifying"))
        networkActivity = String(localized: "Identifying \(r.displayTitle)")
        await identify.identify(r, members: members, settings: settings, fastPathWhenTagged: true)
        networkActivity = nil
        if let error = identify.error(for: r) {
            set(members, .failed, note: error)
        } else if let result = r.identification, result.isConfident, TagService.chosenCandidate(r) != nil {
            set(members, .readyToFinish, note: nil)
        } else if let result = r.identification, let best = result.best, best.origins.contains(.tagMBID),
                  best.trackCountMatches == true, (best.durationFit ?? 1) >= 0.8 {
            // The release the files already name, and it fits: confirmed.
            identify.select(best, for: r, members: members)
            set(members, .readyToFinish, note: nil)
        } else if let result = r.identification, !result.candidates.isEmpty {
            let best = result.best.map { "\($0.candidate.artist) – \($0.candidate.title) (\($0.confidence.rawValue))" } ?? ""
            set(members, .review, note: String(localized: "No sure match; best: \(best)"))
        } else {
            set(members, .review, note: String(localized: "No release found"))
        }
        save()
    }

    private func finishStep(_ r: AlbumRecord) async {
        guard let library, let disc, let tagging, let settings else { return }
        let members = library.members(of: r)
        set(members, .working, note: String(localized: "Writing tags"))
        if dryRun, members.contains(where: Workflow.needsFiles) {
            let what = r.kind == .sacdISO ? String(localized: "extract") : String(localized: "split")
            set(members, .done, note: String(localized: "Would \(what) the disc and tag it as \(Self.describe(TagService.chosenCandidate(r)))"))
            save()
            return
        }
        if mode == .updateInPlace, members.contains(where: Workflow.needsFiles) {
            // Updating in place never creates new track files in the library.
            set(members, .review, note: String(localized: "SACD or CD image: new tracks would have to be written; use Import to extract or split it"))
            save()
            return
        }
        if members.contains(where: Workflow.needsFiles) {
            cpuActivity = String(localized: "Preparing files for \(r.displayTitle)")
            guard await Workflow.produceFiles(members, disc: disc, settings: settings) else {
                cpuActivity = nil
                set(members, .failed, note: r.errorMessage ?? String(localized: "Could not produce the track files"))
                save()
                return
            }
        }
        cpuActivity = String(localized: "Tagging \(r.displayTitle)")
        // A preview may already be running (the inspector of the selected
        // album): wait for it and use it rather than giving up.
        while tagging.isBusy(r) { try? await Task.sleep(for: .milliseconds(200)) }
        if tagging.plan(for: r)?.candidateID != TagService.chosenCandidate(r)?.id {
            await tagging.buildPlan(r, members: members, settings: settings)
        }
        guard let plan = tagging.plan(for: r) else {
            cpuActivity = nil
            set(members, .review, note: tagging.error(for: r) ?? String(localized: "No tag preview"))
            save()
            return
        }
        if !plan.warnings.isEmpty {
            // Track counts or files that do not line up: a person decides.
            cpuActivity = nil
            set(members, .review, note: plan.warnings.joined(separator: " "))
            save()
            return
        }
        let chosen = TagService.chosenCandidate(r)
        // Files that name another release than the one identified: never
        // overwrite a choice someone made; show both and let them decide.
        if !plan.alreadyTagged, let existing = Self.existingReleaseKey(plan), let chosen, existing != Self.releaseKey(chosen) {
            cpuActivity = nil
            set(members, .review, note: String(localized: "Tagged as another release (\(existing)); drtagger suggests \(Self.describe(chosen))"))
            save()
            return
        }
        // The same release elsewhere in the library.
        if let chosen, let index {
            let own = Set(plan.tracks.map { $0.url.deletingLastPathComponent().standardizedFileURL.path })
            if let dup = index.duplicates(of: chosen, excluding: own).first {
                cpuActivity = nil
                set(members, .review, note: String(localized: "Already in the library: \(dup.folder)"))
                save()
                return
            }
        }
        if dryRun {
            cpuActivity = nil
            let changed = plan.tracks.flatMap { $0.changedFields.map(\.name) }
            let fields = Array(NSOrderedSet(array: changed)).compactMap { $0 as? String }
            let note: String
            if plan.alreadyTagged { note = String(localized: "Already tagged with this release") }
            else if !plan.hasWork { note = String(localized: "Tags already match") }
            else { note = String(localized: "Would write \(fields.count) field(s): \(fields.prefix(6).joined(separator: ", "))\(fields.count > 6 ? "…" : "")") + (plan.cover != nil ? String(localized: " + cover") : "") }
            set(members, .done, note: note)
            save()
            return
        }
        // Already tagged with this very release, or nothing would change:
        // leave the files alone (only move them when importing).
        if plan.alreadyTagged || !plan.hasWork {
            var note = plan.alreadyTagged ? String(localized: "Already tagged with this release; nothing written") : String(localized: "Tags already matched; nothing written")
            if mode == .importToLibrary {
                if let problem = await tagging.organizeOnly(r, members: members, settings: settings) {
                    cpuActivity = nil
                    set(members, .failed, note: problem)
                    save()
                    return
                }
                note += String(localized: "; moved into the library")
            }
            cpuActivity = nil
            set(members, .done, note: note)
            save()
            return
        }
        await tagging.apply(r, members: members, settings: settings, organize: mode == .importToLibrary)
        cpuActivity = nil
        if let error = tagging.error(for: r) {
            set(members, .failed, note: error)
        } else {
            set(members, .done, note: nil)
            let folders = Set(members.flatMap { $0.tagReports.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent() } })
            await index?.update(folders: Array(folders))
        }
        save()
    }

    // MARK: Helpers

    nonisolated static func releaseKey(_ c: Candidate) -> String {
        c.source == .musicbrainz ? "mb:" + c.providerID.lowercased() : c.source == .discogs ? "discogs:" + c.providerID : c.id
    }

    // The release the files already name, if they agree on one.
    static func existingReleaseKey(_ plan: TagPlan) -> String? {
        let keys = plan.tracks.map { t -> String? in
            if let mb = t.existing.first(TagField.mbAlbumID), !mb.isEmpty { return "mb:" + mb.lowercased() }
            if let d = t.existing.first(TagField.discogsReleaseID), !d.isEmpty { return "discogs:" + d }
            return nil
        }
        guard let first = keys.first ?? nil, keys.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    nonisolated static func describe(_ c: Candidate?) -> String {
        guard let c else { return "?" }
        return "\(c.artist) – \(c.title)" + " (" + [c.year, c.country, c.catalogNumber].compactMap { $0 }.joined(separator: ", ") + ")"
    }

    private func set(_ records: [AlbumRecord], _ status: BatchStatus, note: String?) {
        for r in records { r.batchStatus = status; r.batchNote = note }
    }

    private func save() { try? library?.container.mainContext.save() }
}
