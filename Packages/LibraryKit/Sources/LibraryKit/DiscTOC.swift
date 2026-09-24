import CryptoKit
import Foundation

// Table of contents of a CD reconstructed from a CUE sheet plus the real
// length of the audio file(s). Offsets are absolute CD frames including the
// 150-frame (2 s) lead-in, as MusicBrainz and FreeDB expect. Validated
// against the REM DISCID of real EAC/XLD rips (2026-09-20).
public struct DiscTOC: Sendable, Equatable, Codable, Hashable {

    public enum TOCError: LocalizedError, Equatable {
        case noAudioTracks
        case fileCountMismatch(expected: Int, got: Int)
        case missingIndex01(track: Int)
        case notMonotonic(track: Int)
        case tooManyTracks(Int)

        public var errorDescription: String? {
            switch self {
            case .noAudioTracks: return "The CUE sheet has no audio tracks."
            case .fileCountMismatch(let e, let g): return "CUE references \(e) files but \(g) lengths were supplied."
            case .missingIndex01(let t): return "Track \(t) has no INDEX 01."
            case .notMonotonic(let t): return "Track \(t) starts before the previous track."
            case .tooManyTracks(let n): return "\(n) tracks exceed the 99 a CD can hold."
            }
        }
    }

    public static let leadInFrames = 150
    public static let dataTrackGapFrames = 11400   // 152 s gap before a data track (enhanced CDs)

    public let firstTrack: Int
    public let lastTrack: Int
    public let trackOffsets: [Int]     // absolute frames, one per audio track
    public let leadOut: Int            // absolute frames

    public init(firstTrack: Int, lastTrack: Int, trackOffsets: [Int], leadOut: Int) {
        self.firstTrack = firstTrack
        self.lastTrack = lastTrack
        self.trackOffsets = trackOffsets
        self.leadOut = leadOut
    }

    // `fileFrames` is the length in CD frames of each FILE in the sheet, in
    // order. Multi-file sheets are laid out back to back, as on the disc.
    public init(cue: CueSheet, fileFrames: [Int]) throws {
        guard fileFrames.count == cue.files.count else {
            throw TOCError.fileCountMismatch(expected: cue.files.count, got: fileFrames.count)
        }
        var fileStart: [Int] = []
        var acc = 0
        for frames in fileFrames {
            fileStart.append(acc)
            acc += frames
        }
        let totalFrames = acc

        var offsets: [Int] = []
        var dataTrackOffset: Int? = nil
        var lastNumber = 0
        for (fileIndex, file) in cue.files.enumerated() {
            for track in file.tracks {
                guard let start = track.start, fileIndex + track.startFileOffset < fileStart.count else { throw TOCError.missingIndex01(track: track.number) }
                let absolute = fileStart[fileIndex + track.startFileOffset] + start.frames + DiscTOC.leadInFrames
                if track.isAudio {
                    if let last = offsets.last, absolute < last { throw TOCError.notMonotonic(track: track.number) }
                    offsets.append(absolute)
                    lastNumber = track.number
                } else if dataTrackOffset == nil {
                    dataTrackOffset = absolute
                }
            }
        }
        guard !offsets.isEmpty else { throw TOCError.noAudioTracks }
        guard offsets.count <= 99 else { throw TOCError.tooManyTracks(offsets.count) }

        let first = cue.audioTracks.first?.number ?? 1
        // Enhanced CD: the audio session ends 11400 frames before the data track.
        let leadOut = dataTrackOffset.map { $0 - DiscTOC.dataTrackGapFrames } ?? (totalFrames + DiscTOC.leadInFrames)
        self.init(firstTrack: first, lastTrack: lastNumber, trackOffsets: offsets, leadOut: leadOut)
    }

    public var trackCount: Int { trackOffsets.count }

    // MusicBrainz Disc ID: SHA-1 over first/last track and 100 offsets in
    // upper-case hex, base64 with the URL-safe substitutions '+'→'.',
    // '/'→'_', '='→'-'. https://musicbrainz.org/doc/Disc_ID_Calculation
    public var musicBrainzDiscID: String {
        var s = String(format: "%02X%02X%08X", firstTrack, lastTrack, leadOut)
        for i in 0..<99 {
            let offset = i < trackOffsets.count ? trackOffsets[i] : 0
            s += String(format: "%08X", offset)
        }
        let digest = Insecure.SHA1.hash(data: Data(s.utf8))
        let b64 = Data(digest).base64EncodedString()
        return b64.replacingOccurrences(of: "+", with: ".")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "-")
    }

    // Classic FreeDB / CDDB ID, the value EAC writes as REM DISCID.
    public var freeDBDiscID: String {
        func digitSum(_ n: Int) -> Int {
            var n = n, sum = 0
            while n > 0 { sum += n % 10; n /= 10 }
            return sum
        }
        let n = trackOffsets.reduce(0) { $0 + digitSum($1 / 75) }
        let totalSeconds = leadOut / 75 - trackOffsets[0] / 75
        let id = ((n % 0xFF) << 24) | (totalSeconds << 8) | trackOffsets.count
        return String(format: "%08X", id)
    }

    // The `toc` parameter CUETools DB expects: track starts and lead-out in
    // frames relative to the start of the program area (no lead-in).
    public var ctdbTOCString: String {
        (trackOffsets + [leadOut]).map { String($0 - DiscTOC.leadInFrames) }.joined(separator: ":")
    }

    // The `toc` query parameter for MusicBrainz's /ws/2/discid lookups:
    // "first last leadout offset1 offset2 …".
    public var musicBrainzTOCString: String {
        ([firstTrack, lastTrack, leadOut] + trackOffsets).map(String.init).joined(separator: " ")
    }

    public var musicBrainzLookupURL: URL {
        URL(string: "https://musicbrainz.org/ws/2/discid/\(musicBrainzDiscID)?toc=\(musicBrainzTOCString.replacingOccurrences(of: " ", with: "+"))&inc=recordings+artist-credits+labels&fmt=json")!
    }
}
