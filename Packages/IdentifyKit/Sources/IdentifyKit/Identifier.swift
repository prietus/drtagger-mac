import Foundation
import LibraryKit
import ProviderKit
import SplitKit

public struct IdentifierConfig: Sendable {
    public var userAgent: String
    public var acoustIDKey: String?
    public var discogsToken: String?
    public var scanArtwork = true
    public var useFingerprints = true
    public var maxDetailFetches = 12
    public var maxCandidates = 25

    public init(userAgent: String, acoustIDKey: String? = nil, discogsToken: String? = nil) {
        self.userAgent = userAgent
        self.acoustIDKey = acoustIDKey
        self.discogsToken = discogsToken
    }
}

public struct IdentificationResult: Sendable, Codable, Hashable {
    public let signals: AlbumSignals
    public let fingerprints: FingerprintOutcome?
    public let candidates: [ScoredCandidate]        // best first
    public let discogsCandidates: [Candidate]       // for the credits merge later
    public let log: [String]
    public let startedAt: Date
    public let elapsedSeconds: Double

    public var best: ScoredCandidate? { candidates.first }
    public var isConfident: Bool {
        guard let best else { return false }
        guard best.confidence == .confident else { return false }
        // A confident pick must stand clear of the runner-up.
        if let second = candidates.dropFirst().first, second.confidence == .confident, second.score >= best.score - 5 {
            return false
        }
        return true
    }
}

public struct IdentifyProgress: Sendable, Equatable {
    public let fraction: Double
    public let message: String
}

// Runs the whole identification for one album.
public actor Identifier {

    public let config: IdentifierConfig
    public let tool: FFmpegTool
    private let musicBrainz: MusicBrainzClient
    private let discogs: DiscogsClient?
    private let acoustID: AcoustIDClient?

    public init(config: IdentifierConfig, tool: FFmpegTool) {
        self.config = config
        self.tool = tool
        musicBrainz = MusicBrainzClient(userAgent: config.userAgent)
        discogs = config.discogsToken.flatMap { $0.isEmpty ? nil : DiscogsClient(userAgent: config.userAgent, token: $0) }
        acoustID = config.acoustIDKey.flatMap { $0.isEmpty ? nil : AcoustIDClient(clientKey: $0, userAgent: config.userAgent) }
    }

    public func identify(
        album: DetectedAlbum,
        toc: DiscTOC? = nil,
        ctdb: [CUEToolsDBClient.Metadata] = [],
        extractedTracks: [URL] = [],
        progress: @escaping @Sendable (IdentifyProgress) -> Void = { _ in }
    ) async -> IdentificationResult {
        let started = Date()
        let logBox = LogBox()
        let log: @Sendable (String) -> Void = { logBox.append($0) }

        progress(IdentifyProgress(fraction: 0.05, message: "Reading signals"))
        var options = SignalCollector.Options()
        options.scanArtwork = config.scanArtwork
        let signals = await SignalCollector(tool: tool).collect(album: album, toc: toc, ctdb: ctdb, extractedTracks: extractedTracks, options: options, log: log)
        return await pipeline(signals: signals, started: started, logBox: logBox, progress: progress)
    }

    // Several albums that are one release: every disc's signals, matched
    // medium by medium.
    public func identify(
        set members: [SignalCollector.SetMember],
        declaredTotal: Int? = nil,
        ctdb: [CUEToolsDBClient.Metadata] = [],
        progress: @escaping @Sendable (IdentifyProgress) -> Void = { _ in }
    ) async -> IdentificationResult {
        let started = Date()
        let logBox = LogBox()
        let log: @Sendable (String) -> Void = { logBox.append($0) }
        progress(IdentifyProgress(fraction: 0.05, message: "Reading signals of \(members.count) discs"))
        var options = SignalCollector.Options()
        options.scanArtwork = config.scanArtwork
        let signals = await SignalCollector(tool: tool).collect(set: members, declaredTotal: declaredTotal, ctdb: ctdb, options: options, log: log)
        return await pipeline(signals: signals, started: started, logBox: logBox, progress: progress)
    }

    private func pipeline(signals: AlbumSignals, started: Date, logBox: LogBox, progress: @escaping @Sendable (IdentifyProgress) -> Void) async -> IdentificationResult {
        let log: @Sendable (String) -> Void = { logBox.append($0) }
        log("Signals: \(signals.uniqueBarcodes.count) barcode(s), \(signals.uniqueCatalogNumbers.count) catalog number(s), \(signals.uniqueReleaseIDs.count) MBID(s), disc ID \(signals.discID ?? "none"), \(signals.trackCount) track(s)\(signals.isSet ? ", discs \(signals.presentDiscs.map(String.init).joined(separator: ",")) of \(signals.discCount)" : "").")

        // Candidate pool keyed by MBID, remembering how each one got in.
        var pool: [String: Candidate] = [:]
        var origins: [String: Set<CandidateOrigin>] = [:]
        var order: [String] = []
        func add(_ c: Candidate, _ origin: CandidateOrigin) {
            guard c.source == .musicbrainz else { return }
            if pool[c.providerID] == nil {
                order.append(c.providerID)
                pool[c.providerID] = c
            } else if pool[c.providerID]!.allTracks.isEmpty && !c.allTracks.isEmpty {
                pool[c.providerID] = c
            }
            origins[c.providerID, default: []].insert(origin)
        }

        // 1. MBIDs from tags / CUETools DB.
        for id in signals.mbReleaseIDs {
            if let c = try? await musicBrainz.releaseDetail(id: id.value) {
                add(c, id.origin == .tags ? .tagMBID : .ctdbMBID)
            }
        }

        // 2. Disc ID / TOC, one lookup per local disc.
        var lookups: [(Int, String, String?)] = signals.discIDs.keys.sorted().map { ($0, signals.discIDs[$0]!, signals.tocStrings[$0]) }
        if lookups.isEmpty, let discID = signals.discID { lookups = [(1, discID, signals.tocString)] }
        for (position, discID, toc) in lookups.prefix(4) {
            progress(IdentifyProgress(fraction: 0.2, message: lookups.count > 1 ? "Looking up disc \(position) ID" : "Looking up disc ID"))
            if let releases = try? await musicBrainz.lookupDiscID(discID, toc: toc) {
                for r in releases { add(r, r.allDiscIDs.contains(discID) ? .discID : .tocMatch) }
                log("MusicBrainz TOC lookup (disc \(position)): \(releases.count) release(s).")
            }
        }

        // 3. Barcodes and catalog numbers.
        progress(IdentifyProgress(fraction: 0.3, message: "Searching by barcode and catalog number"))
        for barcode in signals.uniqueBarcodes.prefix(3) {
            do {
                let rs = try await musicBrainz.searchByBarcode(barcode)
                for r in rs { add(r, .barcode) }
                log("Barcode \(barcode): \(rs.count) MusicBrainz release(s).")
            } catch {
                log("Barcode \(barcode): search failed (\(error.localizedDescription)).")
            }
        }
        for catno in signals.uniqueCatalogNumbers.prefix(4) {
            do {
                let rs = try await musicBrainz.searchByCatalog(catno, limit: 8)
                let plausible = rs.filter { signals.isSet || signals.trackCount == 0 || $0.trackCount == nil || $0.plausibleTrackCounts.contains(signals.trackCount) }
                for r in plausible { add(r, .catalogNumber) }
                log("Catalog \(catno): \(rs.count) release(s), \(plausible.count) with a plausible track count.")
            } catch {
                log("Catalog \(catno): search failed (\(error.localizedDescription)).")
            }
        }

        // 4. Fingerprints.
        var fingerprints: FingerprintOutcome? = nil
        if config.useFingerprints, let acoustID {
            progress(IdentifyProgress(fraction: 0.45, message: "Fingerprinting tracks"))
            let service = FingerprintService(tool: tool, acoustID: acoustID)
            let outcome = await service.run(tracks: signals.tracks, log: log)
            fingerprints = outcome
            var groups: [String] = []
            for vote in outcome.votes.prefix(8) {
                if let c = pool[vote.releaseID] {
                    origins[c.providerID, default: []].insert(.fingerprint)
                    if let g = c.releaseGroupID, !groups.contains(g) { groups.append(g) }
                } else if let c = try? await musicBrainz.releaseDetail(id: vote.releaseID) {
                    add(c, .fingerprint)
                    if let g = c.releaseGroupID, !groups.contains(g) { groups.append(g) }
                }
            }
            // Sibling editions of the strongest groups: the fingerprint only
            // knows the recording, not the pressing.
            for g in groups.prefix(2) {
                if let siblings = try? await musicBrainz.releasesInGroup(id: g) {
                    for s in siblings { add(s, .releaseGroup) }
                }
            }
        } else if config.useFingerprints {
            log("Fingerprints skipped: no AcoustID key configured.")
        }

        // 5. Text search: cheap, and the only way to reach editions the
        // strong signals missed (limit 15 keeps SACD/vinyl variants in reach).
        if let title = signals.albumHint, !title.isEmpty {
            progress(IdentifyProgress(fraction: 0.7, message: "Searching by title"))
            // With an edition in the name, ask for it first: the plain title
            // search ranks the original pressings ahead of reissues.
            if let edition = signals.editionHint {
                do {
                    let rs = try await musicBrainz.searchReleases(artist: signals.artistHint ?? "", album: "\(title) \(edition)", limit: 10)
                    for r in rs { add(r, .textSearch) }
                    log("Text search \"\(title) \(edition)\": \(rs.count) release(s).")
                } catch {
                    log("Text search with edition failed: \(error.localizedDescription)")
                }
            }
            do {
                let rs = try await musicBrainz.searchReleases(artist: signals.artistHint ?? "", album: title, limit: pool.count < 3 ? 15 : 8)
                for r in rs { add(r, .textSearch) }
                log("Text search \"\(title)\": \(rs.count) release(s).")
            } catch {
                log("Text search failed: \(error.localizedDescription)")
            }
        }

        // 6. Details for candidates that arrived without tracks, best first.
        progress(IdentifyProgress(fraction: 0.8, message: "Fetching release details"))
        var detailFetches = 0
        let provisional = order.map { id -> (String, Double) in
            let c = pool[id]!
            let s = MatchScorer.score(c, signals: signals, origins: Array(origins[id] ?? []), fingerprintVote: fingerprints?.votes.first { $0.releaseID == id }, fingerprintedTracks: fingerprints?.fingerprintedTracks ?? 0)
            return (id, s.score)
        }.sorted { $0.1 > $1.1 }
        for (id, _) in provisional where pool[id]!.allTracks.isEmpty && detailFetches < config.maxDetailFetches {
            if let c = try? await musicBrainz.releaseDetail(id: id) {
                pool[id] = c
                detailFetches += 1
            }
        }

        // 7. Discogs, for the credits merge and as extra editions.
        var discogsCandidates: [Candidate] = []
        if let discogs {
            for barcode in signals.uniqueBarcodes.prefix(2) {
                if let rs = try? await discogs.searchByBarcode(barcode) { discogsCandidates.append(contentsOf: rs) }
            }
            if discogsCandidates.isEmpty, let catno = signals.uniqueCatalogNumbers.first {
                if let rs = try? await discogs.searchByCatalog(catno) { discogsCandidates.append(contentsOf: rs) }
            }
        }

        // 8. Final scoring.
        progress(IdentifyProgress(fraction: 0.95, message: "Scoring"))
        var scored = order.map { id -> ScoredCandidate in
            MatchScorer.score(pool[id]!, signals: signals, origins: Array(origins[id] ?? []).sorted { $0.rawValue < $1.rawValue },
                              fingerprintVote: fingerprints?.votes.first { $0.releaseID == id },
                              fingerprintedTracks: fingerprints?.fingerprintedTracks ?? 0)
        }
        scored.sort { ($0.score, $0.confidence) > ($1.score, $1.confidence) }
        if scored.count > config.maxCandidates { scored = Array(scored.prefix(config.maxCandidates)) }
        if let best = scored.first {
            log("Best: \(best.candidate.artist) – \(best.candidate.title) (\(best.candidate.year ?? "?"), \(best.candidate.country ?? "?")) score \(Int(best.score)) \(best.confidence.rawValue).")
        } else {
            log("No candidates found.")
        }
        progress(IdentifyProgress(fraction: 1, message: "Done"))

        return IdentificationResult(
            signals: signals,
            fingerprints: fingerprints,
            candidates: scored,
            discogsCandidates: discogsCandidates,
            log: logBox.lines,
            startedAt: started,
            elapsedSeconds: Date().timeIntervalSince(started)
        )
    }

    private final class LogBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _lines: [String] = []
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }
        func append(_ s: String) { lock.lock(); _lines.append(s); lock.unlock() }
    }
}
