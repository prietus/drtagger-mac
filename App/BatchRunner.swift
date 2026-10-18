import Foundation
import IdentifyKit
import LibraryKit
import Observation

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

    func attach(library: LibraryController, identify: IdentifyService, disc: DiscService, tagging: TagService, settings: AppSettings) {
        self.library = library; self.identify = identify; self.disc = disc; self.tagging = tagging; self.settings = settings
    }

    // MARK: Control

    // Marks every unfinished album of the queue and starts the workers.
    func start(mode: Mode) {
        guard !isRunning, let library else { return }
        self.mode = mode
        for r in library.allRecords() where r.batchStatus == nil || r.batchStatus == .failed {
            if r.taggedAt != nil { continue }
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
        Task {
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
        r.kind == .sacdISO && members.contains(where: Workflow.needsFiles)
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
        await identify.identify(r, members: members, settings: settings)
        networkActivity = nil
        if let error = identify.error(for: r) {
            set(members, .failed, note: error)
        } else if let result = r.identification, result.isConfident, TagService.chosenCandidate(r) != nil {
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
        }
        save()
    }

    // MARK: Helpers

    private func set(_ records: [AlbumRecord], _ status: BatchStatus, note: String?) {
        for r in records { r.batchStatus = status; r.batchNote = note }
    }

    private func save() { try? library?.container.mainContext.save() }
}
