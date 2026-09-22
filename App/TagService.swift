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
    let disc: Int                        // 1-based disc position on the release
    let owner: String                    // path of the record that owns the file
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
    private var leaders: [String: String] = [:]     // member path → plan key (the set's first record)

    private func key(_ record: AlbumRecord) -> String { leaders[record.path] ?? record.path }
    func isBusy(_ record: AlbumRecord) -> Bool { activity[key(record)] != nil }
    func activity(for record: AlbumRecord) -> Activity? { activity[key(record)] }
    func error(for record: AlbumRecord) -> String? { errors[key(record)] }
    func plan(for record: AlbumRecord) -> TagPlan? { plans[key(record)] }

    // The release the tags come from: the user's pick, else a confident best.
    static func chosenCandidate(_ record: AlbumRecord) -> Candidate? {
        if let c = record.selectedCandidate?.candidate { return c }
        if let r = record.identification, r.isConfident { return r.best?.candidate }
        return nil
    }

    // Files that receive the tags, each with the disc position and track
    // index it maps to on the release, and the record that owns it.
    static func targetFiles(_ record: AlbumRecord, members: [AlbumRecord] = []) -> (targets: [(url: URL, disc: Int, track: Int, owner: String)], problem: String?) {
        var out: [(URL, Int, Int, String)] = []
        for m in (members.isEmpty ? [record] : members) {
            if m.state == .applying {
                return ([], String(localized: "Disc \(m.discPosition) is still being extracted or split; wait for it to finish."))
            }
            switch m.kind {
            case .sacdISO:
                guard !m.sacdOutcomes.isEmpty else { return ([], String(localized: "Extract the SACD first; the DSF tracks receive the tags.")) }
                for o in m.sacdOutcomes { for t in o.tracks { out.append((m.resolved(t.url), m.discPosition, t.number - 1, m.path)) } }
            case .cueImage:
                let outcomes = m.splitOutcomes
                guard !outcomes.isEmpty else { return ([], String(localized: "Split the image first; the FLAC tracks receive the tags.")) }
                let discNumbers = (m.detected?.discs.count ?? 1) > 1 ? (m.detected?.discs.map(\.number).sorted() ?? []) : [m.discPosition]
                for (i, o) in outcomes.enumerated() {
                    let disc = i < discNumbers.count ? discNumbers[i] : i + 1
                    for t in o.tracks where t.number > 0 { out.append((m.resolved(t.url), disc, t.number - 1, m.path)) }
                }
            case .cueMultiFile, .trackFolder:
                guard let detected = m.detected else { continue }
                let discs = detected.discs.sorted { $0.number < $1.number }
                for disc in discs {
                    let position = discs.count > 1 ? disc.number : m.discPosition
                    for (i, f) in disc.trackFiles.enumerated() { out.append((m.resolved(f.url), position, i, m.path)) }
                }
            }
        }
        return (out.map { (url: $0.0, disc: $0.1, track: $0.2, owner: $0.3) }, nil)
    }

    func buildPlan(_ record: AlbumRecord, members: [AlbumRecord] = [], settings: AppSettings) async {
        let members = members.isEmpty ? [record] : members
        let leader = members.first ?? record
        for m in members { leaders[m.path] = leader.path }
        guard !isBusy(record) else { return }
        let path = leader.path
        errors[path] = nil
        guard let candidate = Self.chosenCandidate(leader) else {
            errors[path] = String(localized: "Choose a release in Identification first.")
            return
        }
        let (targets, problem) = Self.targetFiles(record, members: members)
        if let problem { errors[path] = problem; return }
        guard !targets.isEmpty else { errors[path] = String(localized: "No audio files to tag."); return }
        activity[path] = Activity(message: String(localized: "Reading tags…"), fraction: nil)
        defer { activity[path] = nil }

        let identification = leader.identification
        let media = MatchScorer.relevantMedia(candidate, localFormat: identification?.signals.localFormat ?? .unknown)
        let mediaList = media.isEmpty ? [CandidateMedium(position: 1, tracks: candidate.tracks)] : media
        var context = TagContext()
        context.discogs = identification?.discogsCandidates.first
        context.musicBrainzDiscID = leader.toc?.musicBrainzDiscID
        context.freedbDiscID = leader.toc?.freeDBDiscID
        context.writeGenres = settings.writeGenresFromDiscogs
        context.acoustIDs = identification?.fingerprints?.acoustIDs ?? [:]
        let locks = leader.tagLocks
        var warnings: [String] = []
        // Per disc: what the release lists against what the files cover.
        let localDiscs = Set(targets.map(\.disc)).sorted()
        for disc in localDiscs {
            let local = targets.filter { $0.disc == disc }.count
            if disc > mediaList.count {
                warnings.append(String(localized: "Disc \(disc): the release has only \(mediaList.count) disc(s); its files are left untouched."))
            } else if mediaList[disc - 1].tracks.count != local {
                warnings.append(String(localized: "Disc \(disc): the release lists \(mediaList[disc - 1].tracks.count) tracks, the files are \(local); tags are mapped by position."))
            }
        }
        if mediaList.count > 1 {
            let missing = (1...mediaList.count).filter { !localDiscs.contains($0) }
            if !missing.isEmpty { warnings.append(String(localized: "Discs not present: \(missing.map(String.init).joined(separator: ", ")) of \(mediaList.count).")) }
        }

        let reads: [(URL, Int, Int, String, Result<ContainerContents, any Error>)] = await Task.detached {
            targets.map { t in (t.url, t.disc, t.track, t.owner, Result { try TaggedFile.read(t.url) }) }
        }.value
        var tracks: [TrackPlan] = []
        var index = 0
        for (url, disc, track, owner, read) in reads {
            switch read {
            case .failure(let error):
                warnings.append("\(url.lastPathComponent): \(error.localizedDescription)")
            case .success(let contents):
                guard let proposed = PicardMapper.trackTags(candidate, media: media, disc: disc, track: track, context: context) else {
                    continue
                }
                let (result, changes) = TagMerge.merge(existing: contents.tags, proposed: proposed, locked: locks)
                tracks.append(TrackPlan(url: url, index: index, disc: disc, owner: owner, existing: contents.tags, proposed: proposed, result: result, changes: changes,
                                        existingPictures: contents.pictures.map(PictureInfo.init), audioDigest: contents.audioDigest))
                index += 1
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
            let options = await fetcher.options(for: candidate, discogs: context.discogs, album: leader.detected) { logBox.append($0) }
            plan.artworkOptions = options
            let preferred = leader.coverOptionID.flatMap { id in options.first { $0.id == id } }
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
        let path = key(record)
        guard var plan = plans[path] else { return }
        guard let optionID, let option = plan.artworkOptions.first(where: { $0.id == optionID }) else {
            plan.cover = nil; plan.coverOptionID = nil; plans[path] = plan
            return
        }
        activity[path] = Activity(message: String(localized: "Downloading artwork…"), fraction: nil)
        defer { activity[path] = nil }
        if let art = await CoverArtFetcher(userAgent: IdentifyService.userAgent, fanartKey: settings.isFanartConfigured ? settings.fanartKey.trimmed : nil).fetch(option) {
            plan.cover = art; plan.coverOptionID = optionID
        } else {
            plan.warnings.append(String(localized: "\(option.label): could not be downloaded."))
        }
        plans[path] = plan
    }

    func toggleLock(_ name: String, for record: AlbumRecord, members: [AlbumRecord] = []) {
        var locks = record.tagLocks
        if locks.contains(name) { locks.remove(name) } else { locks.insert(name) }
        for m in (members.isEmpty ? [record] : members) { m.tagLocks = locks }
        let path = key(record)
        guard var plan = plans[path] else { return }
        plan.tracks = plan.tracks.map { t in
            var t = t
            (t.result, t.changes) = TagMerge.merge(existing: t.existing, proposed: t.proposed, locked: locks)
            return t
        }
        plans[path] = plan
        try? record.modelContext?.save()
    }

    func apply(_ record: AlbumRecord, members: [AlbumRecord] = [], settings: AppSettings) async {
        let members = members.isEmpty ? [record] : members
        let leader = members.first ?? record
        let path = key(record)
        guard !isBusy(record), let plan = plans[path] else { return }
        errors[path] = nil
        activity[path] = Activity(message: String(localized: "Writing tags…"), fraction: 0)
        for m in members { m.state = .applying }
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
                let locks = leader.tagLocks
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
        // Every file belongs to one member; backups, reports and moves stay with it.
        let ownerOf = Dictionary(work.map { ($0.url.path, $0.owner) }, uniquingKeysWith: { a, _ in a })
        var backupsByOwner: [String: [TagBackup]] = [:]
        for b in outcome.backups { backupsByOwner[ownerOf[b.path] ?? leader.path, default: []].append(b) }
        var reportsByOwner: [String: [TagWriteReport]] = [:]
        for r in outcome.reports { reportsByOwner[ownerOf[r.path] ?? leader.path, default: []].append(r) }
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
                    var map: [String: String] = [:]
                    for m in moved { map[m.from.path] = m.to.path }
                    for m in members {
                        let mine = map.filter { ownerOf[$0.key] == m.path || (ownerOf[$0.key] == nil && m.path == leader.path) }
                        var moves = m.fileMoves
                        for (from, to) in mine { moves[from] = to }
                        m.fileMoves = moves
                    }
                    for (owner, list) in backupsByOwner { backupsByOwner[owner] = list.map { b in map[b.path].map { b.moved(to: $0) } ?? b } }
                    for (owner, list) in reportsByOwner { reportsByOwner[owner] = list.map { r in map[r.path].map { r.moved(to: $0) } ?? r } }
                    reports = reports.map { r in map[r.path].map { r.moved(to: $0) } ?? r }
                    // A loose folder that moved as a whole is now the album's home.
                    for m in members where m.kind == .trackFolder || m.kind == .cueMultiFile {
                        let folders = Set((reportsByOwner[m.path] ?? []).map { URL(fileURLWithPath: $0.path).deletingLastPathComponent().path })
                        if folders.count == 1, let folder = folders.first, folder != m.path { m.path = folder }
                    }
                } catch {
                    problems.append(String(localized: "Could not move files into the library: \(error.localizedDescription)"))
                }
            }
        }

        // The first backups are the true originals; later applies keep them.
        for m in members {
            if m.tagBackups.isEmpty { m.tagBackups = backupsByOwner[m.path] ?? [] }
            m.tagReports = reportsByOwner[m.path] ?? []
            m.taggedAt = Date()
            m.coverOptionID = plan.coverOptionID
            if problems.isEmpty {
                m.state = .done
                m.errorMessage = nil
            } else {
                m.state = reports.isEmpty ? .error : .done
                m.errorMessage = problems.joined(separator: "\n")
            }
        }
        if !problems.isEmpty { errors[path] = problems.first }
        plans[path] = nil
        activity[path] = nil
        try? record.modelContext?.save()
    }

    func restore(_ record: AlbumRecord, members: [AlbumRecord] = []) async {
        let members = members.isEmpty ? [record] : members
        guard !isBusy(record) else { return }
        let backups = members.flatMap(\.tagBackups)
        guard !backups.isEmpty else { return }
        let path = key(record)
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
            for m in members {
                m.tagBackups = []
                m.tagReports = []
                m.taggedAt = nil
                m.errorMessage = nil
                m.state = m.selectedCandidateID != nil ? .needsReview : .scanned
            }
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
