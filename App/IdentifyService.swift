import Foundation
import IdentifyKit
import LibraryKit
import Observation
import ProviderKit
import SplitKit
import SwiftData

// Runs release identification for one album and stores the result on its
// record. Confident results preselect the best candidate; anything else
// leaves the choice to the user (needs review).
@Observable
@MainActor
final class IdentifyService {

    struct Activity: Equatable {
        var message: String
        var fraction: Double
    }

    private(set) var activity: [String: Activity] = [:]
    private(set) var errors: [String: String] = [:]

    static let userAgent = "drtagger-mac/0.1 (+https://drtagger.priet.us)"

    func isBusy(_ record: AlbumRecord) -> Bool { activity[record.path] != nil }
    func activity(for record: AlbumRecord) -> Activity? { activity[record.path] }
    func error(for record: AlbumRecord) -> String? { errors[record.path] }

    func identify(_ record: AlbumRecord, members: [AlbumRecord] = [], settings: AppSettings) async {
        let members = members.isEmpty ? [record] : members
        guard !isBusy(record), let album = record.detected else { return }
        guard let location = settings.ffmpegLocator.locate(), let probe = location.ffprobe else {
            errors[record.path] = FFmpegLocator.LocateError.notFound.localizedDescription
            return
        }
        let path = record.path
        let paths = members.map(\.path)
        for p in paths { activity[p] = Activity(message: String(localized: "Starting…"), fraction: 0); errors[p] = nil }
        for m in members { m.state = .identifying }

        // Keys come from Settings (Keychain); scripts can pass them on the
        // command line instead so a fresh build never triggers a Keychain
        // access prompt.
        let acoustIDKey = Self.launchArgument("--acoustid-key") ?? (settings.isAcoustIDConfigured ? settings.acoustIDKey.trimmed : nil)
        let discogsToken = Self.launchArgument("--discogs-token") ?? (settings.isDiscogsConfigured ? settings.discogsToken.trimmed : nil)
        var config = IdentifierConfig(userAgent: Self.userAgent, acoustIDKey: acoustIDKey, discogsToken: discogsToken)
        config.scanArtwork = true
        let identifier = Identifier(config: config, tool: FFmpegTool(ffmpeg: location.ffmpeg, ffprobe: probe))
        let toc = record.toc
        let ctdb = record.ctdbReport?.metadata ?? []

        let progress: @Sendable (IdentifyProgress) -> Void = { [weak self] p in
            Task { @MainActor in
                for path in paths { self?.activity[path] = Activity(message: p.message, fraction: p.fraction) }
            }
        }
        let result: IdentificationResult
        if members.count > 1 {
            // A release set: every disc's signals, matched medium by medium.
            let setMembers = members.compactMap { m -> SignalCollector.SetMember? in
                m.detected.map { SignalCollector.SetMember(album: $0, position: m.setPosition ?? 1, toc: m.toc) }
            }
            result = await identifier.identify(set: setMembers, declaredTotal: members.first?.setTotal, ctdb: ctdb, progress: progress)
        } else {
            result = await identifier.identify(album: album, toc: toc, ctdb: ctdb, progress: progress)
        }
        let selected: String?
        let state: AlbumState
        if result.isConfident, let best = result.best {
            selected = best.id
            state = .confident
        } else {
            selected = result.best.flatMap { $0.confidence >= .likely ? $0.id : nil }
            state = result.candidates.isEmpty ? .scanned : .needsReview
        }
        for m in members {
            m.identification = result
            m.selectedCandidateID = selected
            m.state = state
        }
        for p in paths { activity[p] = nil }
        _ = path
        try? record.modelContext?.save()
    }

    static func launchArgument(_ name: String, arguments: [String] = CommandLine.arguments) -> String? {
        guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count, !arguments[i + 1].hasPrefix("--") else { return nil }
        return arguments[i + 1]
    }

    func select(_ candidate: ScoredCandidate?, for record: AlbumRecord, members: [AlbumRecord] = []) {
        for m in (members.isEmpty ? [record] : members) {
            m.selectedCandidateID = candidate?.id
            if candidate != nil, m.state == .scanned { m.state = .needsReview }
        }
        try? record.modelContext?.save()
    }
}
