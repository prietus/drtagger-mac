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
    // Batches over a tagged library: when the files' release ID fits them,
    // only that release is checked (no searches, no fingerprints).
    public var fastPathWhenTagged = false
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
        if let second = runnerUp, second.confidence == .confident, second.score >= best.score - 5 {
            return false
        }
        return true
    }

    // The best candidate's closest rival. The same pressing entered twice
    // (one barcode or catalog number) is not a rival.
    public var runnerUp: ScoredCandidate? {
        guard let best else { return nil }
        return rival(of: best)
    }

    func rival(of pick: ScoredCandidate) -> ScoredCandidate? {
        candidates.first { $0.id != pick.id && !MatchScorer.areTwins($0.candidate, pick.candidate) }
    }

    // Fingerprints alone, but unmistakable: every track matches, the track
    // count and durations (within 2 s on average) fit, no other edition comes
    // within 30 points and no barcode or catalog number found says otherwise.
    // Ties between editions with the same audio stay for a person.
    public var isClearFingerprintMatch: Bool {
        guard let best, (best.fingerprintCoverage ?? 0) >= 0.999, fingerprints?.fingerprintedTracks == signals.trackCount,
              best.trackCountMatches == true,
              (best.durationFit ?? 0) >= 0.75, !MatchScorer.contradictsLocalCodes(best.candidate, signals: signals) else { return false }
        return best.score - (runnerUp?.score ?? 0) >= 30
    }

    // Editions whose audio is proven on every track but that tie on the
    // rest: the cover the album already has can still tell them apart.
    public var coverContenders: [ScoredCandidate] {
        guard let best, (fingerprints?.fingerprintedTracks ?? 0) == signals.trackCount, signals.trackCount > 0 else { return [] }
        let close = candidates.filter { best.score - $0.score < 30 }
        guard close.contains(where: { Self.provesAudio($0, signals: signals) }), close.count > 1 else { return [] }
        return Array(close.prefix(6))
    }

    // Points for a cover that looks like the album's own (Vision distance).
    public static func coverPoints(_ distance: Float?) -> Double {
        guard let d = distance else { return 0 }
        return d < 0.35 ? 30 : d < 0.6 ? 15 : 0
    }

    // The contender that, with the cover's points added, stands 30 points
    // clear of every other edition; nil when the covers do not decide.
    public func coverTieBreak(distances: [String: Float]) -> ScoredCandidate? {
        let contenders = coverContenders
        guard !contenders.isEmpty else { return nil }
        func total(_ c: ScoredCandidate) -> Double { c.score + Self.coverPoints(distances[c.id]) }
        guard let pick = contenders.max(by: { total($0) < total($1) }), Self.provesAudio(pick, signals: signals) else { return nil }
        let rivals = candidates.filter { $0.id != pick.id && !MatchScorer.areTwins($0.candidate, pick.candidate) }
        let rivalBest = rivals.map { contenders.contains($0) ? total($0) : $0.score }.max() ?? 0
        return total(pick) - rivalBest >= 30 ? pick : nil
    }

    static func provesAudio(_ c: ScoredCandidate, signals: AlbumSignals) -> Bool {
        (c.fingerprintCoverage ?? 0) >= 0.999 && c.trackCountMatches == true && (c.durationFit ?? 0) >= 0.75
            && c.confidence >= .likely
            && !MatchScorer.contradictsLocalCodes(c.candidate, signals: signals)
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
        let clients = ProviderClients.shared(userAgent: config.userAgent, acoustIDKey: config.acoustIDKey, discogsToken: config.discogsToken)
        musicBrainz = clients.musicBrainz
        discogs = clients.discogs
        acoustID = clients.acoustID
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
        // MusicBrainz releases are keyed by MBID (fingerprint votes use it);
        // Discogs releases by "discogs:<id>".
        func key(_ c: Candidate) -> String { c.source == .musicbrainz ? c.providerID : c.id }
        func add(_ c: Candidate, _ origin: CandidateOrigin) {
            guard c.source == .musicbrainz || c.source == .discogs else { return }
            let k = key(c)
            if pool[k] == nil {
                order.append(k)
                pool[k] = c
            } else if pool[k]!.allTracks.isEmpty && !c.allTracks.isEmpty {
                pool[k] = c
            }
            origins[k, default: []].insert(origin)
        }

        // 1. MBIDs from tags / CUETools DB.
        for id in signals.mbReleaseIDs {
            if let c = try? await musicBrainz.releaseDetail(id: id.value) {
                add(c, id.origin == .tags ? .tagMBID : .ctdbMBID)
            }
        }

        // The files name a release that fits them: in fast mode (batches over
        // a tagged library) that release is checked and nothing is searched.
        let taggedFit = order.contains { id in
            guard origins[id]?.contains(.tagMBID) == true, let c = pool[id] else { return false }
            let s = MatchScorer.score(c, signals: signals, origins: [.tagMBID], fingerprintVote: nil, fingerprintedTracks: 0)
            return s.trackCountMatches == true && (s.durationFit ?? 1) >= 0.8 && !MatchScorer.contradictsLocalCodes(c, signals: signals)
        }
        if !taggedFit, order.contains(where: { origins[$0]?.contains(.tagMBID) == true }), !signals.uniqueBarcodes.isEmpty || !signals.uniqueCatalogNumbers.isEmpty {
            log("The release ID in the tags does not match the barcode / catalog number found; searching every edition.")
        }
        let fast = config.fastPathWhenTagged && taggedFit
        var fingerprints: FingerprintOutcome? = nil
        var discogsCandidates: [Candidate] = []
        if fast {
            log("Fast path: the release ID in the tags fits the tracks; no other release searched.")
        } else {
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

        // 4. Fingerprints. Skipped when the files' own release ID already
        // fits them (track count and durations): a tagged library needs no
        // audio read, which matters over the network.
        if taggedFit, config.useFingerprints, acoustID != nil {
            log("Fingerprints skipped: the release ID in the tags fits the tracks.")
        } else if config.useFingerprints, let acoustID {
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
                // Rippers sometimes leave the title of another edition (a box
                // set's disc title) in the CUE and tags: try the folder's title.
                if rs.isEmpty, let folderTitle = signals.folderAlbumHint, !folderTitle.isEmpty,
                   MatchScorer.normalize(folderTitle) != MatchScorer.normalize(title) {
                    let more = try await musicBrainz.searchReleases(artist: signals.artistHint ?? "", album: folderTitle, limit: 10)
                    for r in more { add(r, .textSearch) }
                    log("Text search \"\(folderTitle)\" (folder name): \(more.count) release(s).")
                }
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
        for (id, _) in provisional where pool[id]!.source == .musicbrainz && pool[id]!.allTracks.isEmpty && detailFetches < config.maxDetailFetches {
            if let c = try? await musicBrainz.releaseDetail(id: id) {
                pool[id] = c
                detailFetches += 1
            }
        }

        // 7. Discogs: editions MusicBrainz lacks (many Japanese pressings).
        // Barcode / catalog hits are fetched in full and scored like any
        // other candidate; all hits also feed the credits merge.
        if let discogs {
            progress(IdentifyProgress(fraction: 0.88, message: "Searching Discogs"))
            var hits: [(Candidate, CandidateOrigin)] = []
            for barcode in signals.uniqueBarcodes.prefix(2) {
                if let rs = try? await discogs.searchByBarcode(barcode) { hits += rs.map { ($0, .barcode) } }
            }
            for catno in signals.uniqueCatalogNumbers.prefix(2) where hits.count < 6 {
                if let rs = try? await discogs.searchByCatalog(catno) { hits += rs.map { ($0, .catalogNumber) } }
            }
            var fetched = Set<String>()
            for (hit, origin) in hits where fetched.count < 4 && fetched.insert(hit.providerID).inserted {
                if let full = try? await discogs.releaseDetail(id: hit.providerID) {
                    discogsCandidates.append(full)
                    add(full, origin)
                }
            }
            if !hits.isEmpty { log("Discogs: \(hits.count) hit(s) by barcode or catalog, \(fetched.count) fetched and scored.") }
            // DSD files come from a SACD (or a DSD download): when MusicBrainz
            // only knows the CDs, look for the SACD editions on Discogs.
            if signals.localFormat == .sacd, !order.contains(where: { MatchScorer.isSACDEdition(pool[$0]!) }),
               let title = signals.folderAlbumHint ?? signals.albumHint, !title.isEmpty {
                let rs = (try? await discogs.searchReleases(artist: signals.artistHint ?? "", album: title, format: "SACD", limit: 10)) ?? []
                var added = 0
                for hit in rs where added < 3 && fetched.insert(hit.providerID).inserted {
                    if let full = try? await discogs.releaseDetail(id: hit.providerID) {
                        discogsCandidates.append(full)
                        add(full, .textSearch)
                        added += 1
                    }
                }
                log("Discogs SACD search \"\(title)\": \(rs.count) release(s), \(added) fetched and scored.")
            }
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
