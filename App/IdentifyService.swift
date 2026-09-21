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

    func identify(_ record: AlbumRecord, settings: AppSettings) async {
        guard !isBusy(record), let album = record.detected else { return }
        guard let location = settings.ffmpegLocator.locate(), let probe = location.ffprobe else {
            errors[record.path] = FFmpegLocator.LocateError.notFound.localizedDescription
            return
        }
        let path = record.path
        activity[path] = Activity(message: String(localized: "Starting…"), fraction: 0)
        errors[path] = nil
        record.state = .identifying

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

        let result = await identifier.identify(album: album, toc: toc, ctdb: ctdb) { [weak self] p in
            Task { @MainActor in
                self?.activity[path] = Activity(message: p.message, fraction: p.fraction)
            }
        }
        record.identification = result
        if result.isConfident, let best = result.best {
            record.selectedCandidateID = best.id
            record.state = .confident
        } else {
            record.selectedCandidateID = result.best.flatMap { $0.confidence >= .likely ? $0.id : nil }
            record.state = result.candidates.isEmpty ? .scanned : .needsReview
        }
        activity[path] = nil
        try? record.modelContext?.save()
    }

    static func launchArgument(_ name: String, arguments: [String] = CommandLine.arguments) -> String? {
        guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count, !arguments[i + 1].hasPrefix("--") else { return nil }
        return arguments[i + 1]
    }

    func select(_ candidate: ScoredCandidate?, for record: AlbumRecord) {
        record.selectedCandidateID = candidate?.id
        if candidate != nil, record.state == .scanned { record.state = .needsReview }
        try? record.modelContext?.save()
    }
}
