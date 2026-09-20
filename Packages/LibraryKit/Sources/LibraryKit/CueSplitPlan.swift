import Foundation

// Sample-accurate track boundaries for splitting an image (or a run of
// per-track files) described by a CUE sheet.
//
// Gap policy: every track runs from its INDEX 01 to the next track's
// INDEX 01, so a following track's pregap (INDEX 00) stays at the end of
// the previous track, the way EAC and XLD split. Audio before track 1's
// INDEX 01 becomes track 00 (HTOA) when it is longer than
// `htoaThresholdFrames`; a shorter lead-in (the usual 2 s of silence) is
// dropped.
public struct SplitTrack: Sendable, Equatable, Codable, Hashable {
    public let number: Int              // 0 = hidden track one audio
    public let title: String?
    public let performer: String?
    public let isrc: String?
    public let startSample: Int64
    public let endSample: Int64         // exclusive

    public init(number: Int, title: String?, performer: String?, isrc: String?, startSample: Int64, endSample: Int64) {
        self.number = number
        self.title = title
        self.performer = performer
        self.isrc = isrc
        self.startSample = startSample
        self.endSample = endSample
    }

    public var sampleCount: Int64 { endSample - startSample }
    public var isHiddenTrack: Bool { number == 0 }
}

public struct CueSplitPlan: Sendable, Equatable, Codable, Hashable {

    public enum PlanError: LocalizedError, Equatable {
        case fileCountMismatch(expected: Int, got: Int)
        case unsupportedSampleRate(Int)
        case noAudioTracks
        case missingIndex01(track: Int)
        case indexBeyondFile(track: Int)
        case notMonotonic(track: Int)

        public var errorDescription: String? {
            switch self {
            case .fileCountMismatch(let e, let g): return "CUE references \(e) files but \(g) lengths were supplied."
            case .unsupportedSampleRate(let r): return "\(r) Hz is not a multiple of 75 CD frames per second."
            case .noAudioTracks: return "The CUE sheet has no audio tracks."
            case .missingIndex01(let t): return "Track \(t) has no INDEX 01."
            case .indexBeyondFile(let t): return "Track \(t) starts beyond the end of its file."
            case .notMonotonic(let t): return "Track \(t) starts before the previous track."
            }
        }
    }

    public let sampleRate: Int
    public let totalSamples: Int64
    public let tracks: [SplitTrack]       // track 00 first when present
    public let droppedLeadInSamples: Int64 // silence before track 1 that was not kept

    public var hiddenTrack: SplitTrack? { tracks.first { $0.isHiddenTrack } }
    public var numberedTracks: [SplitTrack] { tracks.filter { !$0.isHiddenTrack } }

    // `fileSampleCounts` are the decoded lengths of each FILE in the sheet.
    public static func make(
        cue: CueSheet,
        fileSampleCounts: [Int64],
        sampleRate: Int,
        htoaThresholdFrames: Int = 150
    ) throws -> CueSplitPlan {
        guard fileSampleCounts.count == cue.files.count else {
            throw PlanError.fileCountMismatch(expected: cue.files.count, got: fileSampleCounts.count)
        }
        guard sampleRate > 0, sampleRate % CueTime.framesPerSecond == 0 else {
            throw PlanError.unsupportedSampleRate(sampleRate)
        }
        let samplesPerFrame = Int64(sampleRate / CueTime.framesPerSecond)

        var fileStart: [Int64] = []
        var total: Int64 = 0
        for count in fileSampleCounts {
            fileStart.append(total)
            total += count
        }

        // Absolute start of every audio track.
        struct Start { let track: CueTrack; let sample: Int64 }
        var starts: [Start] = []
        for (fileIndex, file) in cue.files.enumerated() {
            for track in file.tracks where track.isAudio {
                guard let index01 = track.start else { throw PlanError.missingIndex01(track: track.number) }
                let sample = fileStart[fileIndex] + Int64(index01.frames) * samplesPerFrame
                guard sample <= fileStart[fileIndex] + fileSampleCounts[fileIndex] else {
                    throw PlanError.indexBeyondFile(track: track.number)
                }
                if let last = starts.last, sample < last.sample { throw PlanError.notMonotonic(track: track.number) }
                starts.append(Start(track: track, sample: sample))
            }
        }
        guard !starts.isEmpty else { throw PlanError.noAudioTracks }

        var tracks: [SplitTrack] = []
        var dropped: Int64 = 0
        let leadIn = starts[0].sample
        if leadIn > 0 {
            if leadIn > Int64(htoaThresholdFrames) * samplesPerFrame {
                tracks.append(SplitTrack(number: 0, title: nil, performer: nil, isrc: nil, startSample: 0, endSample: leadIn))
            } else {
                dropped = leadIn
            }
        }
        for (i, start) in starts.enumerated() {
            let end = i + 1 < starts.count ? starts[i + 1].sample : total
            tracks.append(SplitTrack(
                number: start.track.number,
                title: start.track.title,
                performer: start.track.performer,
                isrc: start.track.isrc,
                startSample: start.sample,
                endSample: end
            ))
        }
        return CueSplitPlan(sampleRate: sampleRate, totalSamples: total, tracks: tracks, droppedLeadInSamples: dropped)
    }
}
