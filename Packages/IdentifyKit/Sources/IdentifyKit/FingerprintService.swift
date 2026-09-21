import ChromaprintKit
import Foundation
import ProviderKit
import SplitKit

// Chromaprint + AcoustID over the album's tracks, aggregated into votes
// per MusicBrainz release with the consensus filter from drtagger: the
// real album is the release that most tracks hit; releases sharing only a
// song or two are compilations and get dropped.
public struct ReleaseVote: Sendable, Codable, Hashable {
    public let releaseID: String
    public let trackIndices: [Int]
    public let bestScore: Double

    public var hitCount: Int { trackIndices.count }
}

public struct FingerprintOutcome: Sendable, Codable, Hashable {
    public let fingerprintedTracks: Int
    public let tracksWithHits: Int
    public let votes: [ReleaseVote]           // after the consensus filter, best first
    public let recordingIDs: [Int: String]    // local track index → recording MBID of the best hit

    public var coverage: Double {
        guard fingerprintedTracks > 0, let best = votes.first else { return 0 }
        return Double(best.hitCount) / Double(fingerprintedTracks)
    }
}

public struct FingerprintService: Sendable {

    public let tool: FFmpegTool
    public let acoustID: AcoustIDClient
    public var secondsPerTrack: Double = 120
    public var maxConcurrentDecodes = 3

    public init(tool: FFmpegTool, acoustID: AcoustIDClient) {
        self.tool = tool
        self.acoustID = acoustID
    }

    struct TrackHit: Sendable {
        let index: Int
        let matches: [AcoustIDClient.Match]
    }

    public func run(tracks: [LocalTrack], log: @escaping @Sendable (String) -> Void = { _ in }) async -> FingerprintOutcome {
        let candidates = tracks.filter { $0.url != nil }
        guard !candidates.isEmpty else {
            return FingerprintOutcome(fingerprintedTracks: 0, tracksWithHits: 0, votes: [], recordingIDs: [:])
        }
        let fingerprinter = Fingerprinter()
        var hits: [TrackHit] = []
        var fingerprinted = 0

        await withTaskGroup(of: (Int, TrackHit?, Bool).self) { group in
            var iterator = candidates.makeIterator()
            func enqueue() {
                guard let track = iterator.next(), let url = track.url else { return }
                group.addTask {
                    do {
                        let snippet = try await tool.decodeSnippet(url, start: track.imageStart ?? 0, seconds: secondsPerTrack)
                        guard !snippet.samples.isEmpty else { return (track.index, nil, false) }
                        let duration = Int((track.durationSeconds ?? Double(snippet.samples.count / snippet.channels) / Double(snippet.sampleRate)).rounded())
                        let result = try await fingerprinter.fingerprint(
                            samples: snippet.samples, sampleRate: snippet.sampleRate,
                            numChannels: snippet.channels, durationSeconds: max(1, duration)
                        )
                        let matches = try await acoustID.lookup(fingerprint: result.fingerprint, durationSeconds: result.durationSeconds)
                        return (track.index, TrackHit(index: track.index, matches: matches), true)
                    } catch {
                        log("Fingerprint failed for track \(track.index + 1): \(error.localizedDescription)")
                        return (track.index, nil, false)
                    }
                }
            }
            for _ in 0..<maxConcurrentDecodes { enqueue() }
            for await (_, hit, ok) in group {
                if ok { fingerprinted += 1 }
                if let hit { hits.append(hit) }
                enqueue()
            }
        }

        // Votes per release.
        var scores: [String: Double] = [:]
        var trackHits: [String: Set<Int>] = [:]
        var recordingIDs: [Int: String] = [:]
        var tracksWithHits = 0
        for hit in hits where !hit.matches.isEmpty {
            tracksWithHits += 1
            if let best = hit.matches.max(by: { $0.score < $1.score }) {
                recordingIDs[hit.index] = best.recordingID
            }
            for m in hit.matches {
                for r in m.releaseIDs {
                    scores[r] = max(scores[r] ?? 0, m.score)
                    trackHits[r, default: []].insert(hit.index)
                }
            }
        }
        let votes = Self.consensus(scores: scores, trackHits: trackHits, trackCount: fingerprinted)
        log("AcoustID: \(tracksWithHits) of \(fingerprinted) tracks matched; \(votes.count) release(s) after consensus.")
        return FingerprintOutcome(fingerprintedTracks: fingerprinted, tracksWithHits: tracksWithHits, votes: votes, recordingIDs: recordingIDs)
    }

    // Keeps releases hit by at least half of the maximum hit count (and at
    // least two tracks) when the album has more than one track; otherwise
    // everything stays. Sorted by hits, then best score.
    static func consensus(scores: [String: Double], trackHits: [String: Set<Int>], trackCount: Int) -> [ReleaseVote] {
        let maxHits = trackHits.values.map(\.count).max() ?? 0
        let eligible = trackCount > 1 && maxHits >= 2
        let minHits = max(2, (maxHits + 1) / 2)
        return scores.keys.compactMap { id -> ReleaseVote? in
            let hits = trackHits[id] ?? []
            if eligible && hits.count < minHits { return nil }
            return ReleaseVote(releaseID: id, trackIndices: hits.sorted(), bestScore: scores[id] ?? 0)
        }
        .sorted { ($0.hitCount, $0.bestScore) > ($1.hitCount, $1.bestScore) }
    }
}
