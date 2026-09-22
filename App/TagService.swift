import Foundation
import IdentifyKit
import LibraryKit
import LoudnessKit
import Observation
import ProviderKit
import SACDKit
import SplitKit
import SwiftData
import TagKit

// One file of the album with what it has, what the release says and the merge.
struct TrackPlan: Identifiable, Sendable, Equatable {
    let url: URL
    let index: Int                       // 0-based album track index
    let existing: TagSet
    let proposed: TagSet
    var result: TagSet
    var changes: [TagChange]
    let existingPictures: [PictureInfo]
    let audioDigest: String

    var id: String { url.path }
    var changedFields: [TagChange] { changes.filter { $0.kind != .unchanged } }
}

struct TagPlan: Sendable, Equatable {
    var candidateID: String
    var tracks: [TrackPlan]
    var artworkOptions: [ArtworkOption]
    var coverOptionID: String?           // nil: keep the pictures the files have
    var cover: FetchedArtwork?
    var warnings: [String]
    var log: [String]

    // Fields that change the same way on every track: shown once.
    var albumChanges: [TagChange] {
        guard let first = tracks.first else { return [] }
        return first.changes.filter { c in tracks.allSatisfy { t in t.changes.first { $0.name == c.name } == c } }
    }

    func trackOnlyChanges(_ track: TrackPlan) -> [TagChange] {
        let shared = Set(albumChanges.map(\.name))
        return track.changes.filter { !shared.contains($0.name) }
    }

    var changedTrackCount: Int { tracks.filter { !$0.changedFields.isEmpty }.count }
    var changedFieldCount: Int { Set(tracks.flatMap { $0.changedFields.map(\.name) }).count }
    var hasWork: Bool { changedTrackCount > 0 || cover != nil }
}

// Builds tag plans from the chosen release, writes them with backups and
// verification, and restores the originals.
@Observable
@MainActor
final class TagService {

    struct Activity: Equatable {
        var message: String
        var fraction: Double?
    }

    private(set) var activity: [String: Activity] = [:]
    private(set) var errors: [String: String] = [:]
    private(set) var plans: [String: TagPlan] = [:]

    func isBusy(_ record: AlbumRecord) -> Bool { activity[record.path] != nil }
    func activity(for record: AlbumRecord) -> Activity? { activity[record.path] }
    func error(for record: AlbumRecord) -> String? { errors[record.path] }
    func plan(for record: AlbumRecord) -> TagPlan? { plans[record.path] }

    // The release the tags come from: the user's pick, else a confident best.
    static func chosenCandidate(_ record: AlbumRecord) -> Candidate? {
        if let c = record.selectedCandidate?.candidate { return c }
        if let r = record.identification, r.isConfident { return r.best?.candidate }
        return nil
    }

    // Files that receive the tags, with the album track index each maps to.
    static func targetFiles(_ record: AlbumRecord) -> (targets: [(url: URL, index: Int)], problem: String?) {
        let r: (targets: [(url: URL, index: Int)], problem: String?)
        switch record.kind {
        case .sacdISO:
            guard !record.sacdOutcomes.isEmpty else { return ([], String(localized: "Extract the SACD first; the DSF tracks receive the tags.")) }
            r = (record.sacdOutcomes.flatMap { o in o.tracks.map { ($0.url, $0.number - 1) } }, nil)
        case .cueImage:
            guard let split = record.splitOutcome else { return ([], String(localized: "Split the image first; the FLAC tracks receive the tags.")) }
            r = (split.tracks.filter { $0.number > 0 }.map { ($0.url, $0.number - 1) }, nil)
        case .cueMultiFile, .trackFolder:
            guard let detected = record.detected else { return ([], nil) }
            let files = detected.discs.sorted { $0.number < $1.number }.flatMap { $0.trackFiles.map(\.url) }
            r = (files.enumerated().map { ($0.element, $0.offset) }, nil)
        }
        return (r.targets.map { (record.resolved($0.url), $0.index) }, r.problem)
    }

    func buildPlan(_ record: AlbumRecord, settings: AppSettings) async {
        guard !isBusy(record) else { return }
        let path = record.path
        errors[path] = nil
        guard let candidate = Self.chosenCandidate(record) else {
            errors[path] = String(localized: "Choose a release in Identification first.")
            return
        }
        let (targets, problem) = Self.targetFiles(record)
        if let problem { errors[path] = problem; return }
        guard !targets.isEmpty else { errors[path] = String(localized: "No audio files to tag."); return }
        activity[path] = Activity(message: String(localized: "Reading tags…"), fraction: nil)
        defer { activity[path] = nil }

        let identification = record.identification
        let media = MatchScorer.relevantMedia(candidate, localFormat: identification?.signals.localFormat ?? .unknown)
        var context = TagContext()
        context.discogs = identification?.discogsCandidates.first
        context.musicBrainzDiscID = record.toc?.musicBrainzDiscID
        context.freedbDiscID = record.toc?.freeDBDiscID
        context.writeGenres = settings.writeGenresFromDiscogs
        context.acoustIDs = identification?.fingerprints?.acoustIDs ?? [:]
        let locks = record.tagLocks
        var warnings: [String] = []
        let releaseTracks = (media.isEmpty ? [CandidateMedium(position: 1, tracks: candidate.tracks)] : media).reduce(0) { $0 + $1.tracks.count }
        let localTracks = Set(targets.map(\.index)).count
        if releaseTracks != localTracks {
            warnings.append(String(localized: "The release lists \(releaseTracks) tracks, the album has \(localTracks); tags are mapped by position."))
        }

        let reads: [(URL, Int, Result<ContainerContents, any Error>)] = await Task.detached {
            targets.map { t in (t.url, t.index, Result { try TaggedFile.read(t.url) }) }
        }.value
        var tracks: [TrackPlan] = []
        for (url, index, read) in reads {
            switch read {
            case .failure(let error):
                warnings.append("\(url.lastPathComponent): \(error.localizedDescription)")
            case .success(let contents):
                guard let proposed = PicardMapper.trackTags(candidate, media: media, index: index, context: context) else {
                    warnings.append(String(localized: "\(url.lastPathComponent): the release has no track \(index + 1); left untouched."))
                    continue
                }
                let (result, changes) = TagMerge.merge(existing: contents.tags, proposed: proposed, locked: locks)
                tracks.append(TrackPlan(url: url, index: index, existing: contents.tags, proposed: proposed, result: result, changes: changes,
                                        existingPictures: contents.pictures.map(PictureInfo.init), audioDigest: contents.audioDigest))
            }
        }
        guard !tracks.isEmpty else {
            errors[path] = warnings.first ?? String(localized: "No file could be read.")
            return
        }

        var plan = TagPlan(candidateID: candidate.id, tracks: tracks, artworkOptions: [], coverOptionID: nil, cover: nil, warnings: warnings, log: [])
        if settings.embedFrontCover {
            activity[path] = Activity(message: String(localized: "Looking for artwork…"), fraction: nil)
            let logBox = LogBox()
            let fetcher = CoverArtFetcher(userAgent: IdentifyService.userAgent, fanartKey: settings.isFanartConfigured ? settings.fanartKey.trimmed : nil)
            let options = await fetcher.options(for: candidate, discogs: context.discogs, album: record.detected) { logBox.append($0) }
            plan.artworkOptions = options
            let preferred = record.coverOptionID.flatMap { id in options.first { $0.id == id } }
            for option in ([preferred].compactMap { $0 } + options) {
                if let art = await fetcher.fetch(option) {
                    plan.cover = art
                    plan.coverOptionID = option.id
                    logBox.append("Artwork: \(option.label), \(art.width)×\(art.height).")
                    break
                }
            }
            plan.log = logBox.lines
        }
        plans[path] = plan
    }

    // nil keeps the files' own pictures.
    func chooseCover(_ optionID: String?, for record: AlbumRecord, settings: AppSettings) async {
        guard var plan = plans[record.path] else { return }
        guard let optionID, let option = plan.artworkOptions.first(where: { $0.id == optionID }) else {
            plan.cover = nil; plan.coverOptionID = nil; plans[record.path] = plan
            return
        }
        activity[record.path] = Activity(message: String(localized: "Downloading artwork…"), fraction: nil)
        defer { activity[record.path] = nil }
        if let art = await CoverArtFetcher(userAgent: IdentifyService.userAgent, fanartKey: settings.isFanartConfigured ? settings.fanartKey.trimmed : nil).fetch(option) {
            plan.cover = art; plan.coverOptionID = optionID
        } else {
            plan.warnings.append(String(localized: "\(option.label): could not be downloaded."))
        }
        plans[record.path] = plan
    }

    func toggleLock(_ name: String, for record: AlbumRecord) {
        var locks = record.tagLocks
        if locks.contains(name) { locks.remove(name) } else { locks.insert(name) }
        record.tagLocks = locks
        guard var plan = plans[record.path] else { return }
        plan.tracks = plan.tracks.map { t in
            var t = t
            (t.result, t.changes) = TagMerge.merge(existing: t.existing, proposed: t.proposed, locked: locks)
            return t
        }
        plans[record.path] = plan
        try? record.modelContext?.save()
    }

    func apply(_ record: AlbumRecord, settings: AppSettings) async {
        guard !isBusy(record), let plan = plans[record.path] else { return }
        let path = record.path
        errors[path] = nil
        activity[path] = Activity(message: String(localized: "Writing tags…"), fraction: 0)
        record.state = .applying
        let embed: Picture? = plan.cover.flatMap { try? ArtworkProcessor.prepared(from: $0.data, maxPixels: settings.embedCoverMaxPixels) }
        let coverData = settings.saveCoverFile ? plan.cover?.data : nil
        let coverExtension = plan.cover.map { ArtworkProcessor.mimeType(of: $0.data) == "image/png" ? "png" : "jpg" } ?? "jpg"
        var work = plan.tracks
        var problems: [String] = []

        // 1. Loudness first, so ReplayGain lands in the same write.
        if settings.computeReplayGain, let location = settings.ffmpegLocator.locate(), let probe = location.ffprobe {
            activity[path] = Activity(message: String(localized: "Measuring loudness…"), fraction: 0)
            let analyzer = LoudnessAnalyzer(tool: FFmpegTool(ffmpeg: location.ffmpeg, ffprobe: probe))
            do {
                let album = try await analyzer.analyzeAlbum(work.map(\.url)) { [weak self] done, total in
                    Task { @MainActor in self?.activity[path] = Activity(message: String(localized: "Measuring loudness…"), fraction: Double(done) / Double(total)) }
                }
                let locks = record.tagLocks
                for i in work.indices where i < album.tracks.count {
                    let container = TagContainer.from(url: work[i].url)
                    let dsd = container == .dsf || container == .dff
                    for (name, value) in ReplayGain.tags(track: album.tracks[i], album: album, dsd: dsd) where !locks.contains(name) {
                        work[i].result.set(name, value)
                    }
                }
            } catch {
                problems.append(String(localized: "Loudness measurement failed: \(error.localizedDescription)"))
            }
        }
        let workItems = work
        let total = workItems.count
        let progress: @Sendable (Int) -> Void = { [weak self] done in
            Task { @MainActor in self?.activity[path] = Activity(message: String(localized: "Writing tags…"), fraction: Double(done) / Double(total)) }
        }
        let outcome: (backups: [TagBackup], reports: [TagWriteReport], problems: [String]) = await Task.detached {
            var backups: [TagBackup] = [], reports: [TagWriteReport] = [], problems: [String] = []
            for (i, t) in workItems.enumerated() {
                do {
                    let contents = try TaggedFile.read(t.url)
                    backups.append(TagBackup(url: t.url, container: try TaggedFile.container(for: t.url), contents: contents))
                    let pictures: [Picture]? = embed.map { TaggedFile.replacingFront(in: contents.pictures, with: $0) }
                    reports.append(try TaggedFile.write(t.url, tags: t.result, pictures: pictures, expectedDigest: contents.audioDigest))
                } catch {
                    problems.append("\(t.url.lastPathComponent): \(error.localizedDescription)")
                }
                progress(i + 1)
            }
            if let coverData, let first = workItems.first {
                let folder = first.url.deletingLastPathComponent()
                let existing = ["jpg", "jpeg", "png"].map { folder.appending(path: "cover.\($0)") }.first { FileManager.default.fileExists(atPath: $0.path) }
                if existing == nil { try? coverData.write(to: folder.appending(path: "cover.\(coverExtension)")) }
            }
            return (backups, reports, problems)
        }.value
        problems.append(contentsOf: outcome.problems)
        var backups = record.tagBackups.isEmpty ? outcome.backups : record.tagBackups
        var reports = outcome.reports

        // 2. Library layout from the final tags.
        if settings.organizeAfterApply, let root = settings.libraryRootURL, outcome.problems.isEmpty, !reports.isEmpty {
            var options = LibraryOrganizer.Options()
            options.albumFolderTemplate = settings.albumFolderTemplate
            options.trackFileTemplate = settings.trackFileTemplate
            options.asciiFileNames = settings.asciiFileNames
            let files = work.map { (url: $0.url, tags: $0.result) }
            let planned = LibraryOrganizer.plan(files: files, root: root, options: options)
            if !planned.isEmpty {
                activity[path] = Activity(message: String(localized: "Organizing files…"), fraction: nil)
                do {
                    let moved = try await Task.detached { try LibraryOrganizer.perform(planned) }.value
                    var map = record.fileMoves
                    for m in moved { map[m.from.path] = m.to.path }
                    record.fileMoves = map
                    backups = backups.map { b in map[b.path].map { b.moved(to: $0) } ?? b }
                    reports = reports.map { r in map[r.path].map { r.moved(to: $0) } ?? r }
                    // A loose folder that moved as a whole is now the album's home.
                    let folders = Set(reports.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent().path })
                    if record.kind == .trackFolder || record.kind == .cueMultiFile, folders.count == 1, let folder = folders.first, folder != record.path {
                        record.path = folder
                    }
                } catch {
                    problems.append(String(localized: "Could not move files into the library: \(error.localizedDescription)"))
                }
            }
        }

        // The first backups are the true originals; later applies keep them.
        record.tagBackups = backups
        record.tagReports = reports
        record.taggedAt = Date()
        record.coverOptionID = plan.coverOptionID
        if problems.isEmpty {
            record.state = .done
            record.errorMessage = nil
        } else {
            record.state = reports.isEmpty ? .error : .done
            record.errorMessage = problems.joined(separator: "\n")
            errors[path] = problems.first
        }
        plans[path] = nil
        activity[path] = nil
        try? record.modelContext?.save()
    }

    func restore(_ record: AlbumRecord) async {
        guard !isBusy(record) else { return }
        let backups = record.tagBackups
        guard !backups.isEmpty else { return }
        let path = record.path
        activity[path] = Activity(message: String(localized: "Restoring original tags…"), fraction: nil)
        errors[path] = nil
        let problems: [String] = await Task.detached {
            var problems: [String] = []
            for b in backups {
                do { try TaggedFile.restore(URL(fileURLWithPath: b.path), from: b) }
                catch { problems.append("\((b.path as NSString).lastPathComponent): \(error.localizedDescription)") }
            }
            return problems
        }.value
        if problems.isEmpty {
            record.tagBackups = []
            record.tagReports = []
            record.taggedAt = nil
            record.errorMessage = nil
            record.state = record.selectedCandidateID != nil ? .needsReview : .scanned
        } else {
            errors[path] = problems.joined(separator: "\n")
        }
        plans[path] = nil
        activity[path] = nil
        try? record.modelContext?.save()
    }

    private final class LogBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _lines: [String] = []
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }
        func append(_ s: String) { lock.lock(); _lines.append(s); lock.unlock() }
    }
}
