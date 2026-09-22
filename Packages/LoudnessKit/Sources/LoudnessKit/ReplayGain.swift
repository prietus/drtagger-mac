import Foundation

public struct AlbumLoudness: Sendable, Codable, Equatable {
    public let tracks: [LoudnessResult]
    public let integratedLUFS: Double?
    public let truePeakDBTP: Double

    public init(tracks: [LoudnessResult]) {
        self.tracks = tracks
        integratedLUFS = R128Meter.integrated(blockPowers: tracks.flatMap(\.blockPowers))
        truePeakDBTP = tracks.map(\.truePeakDBTP).max() ?? -200
    }
}

// ReplayGain 2.0 (reference -18 LUFS, true peak as a linear factor) and the
// Opus-style R128_* integers (Q7.8 dB relative to -23 LUFS) used for DSD.
public enum ReplayGain {
    public static let referenceLUFS = -18.0
    public static let r128ReferenceLUFS = -23.0

    public static func gainString(_ lufs: Double) -> String { String(format: "%.2f dB", referenceLUFS - lufs) }
    public static func peakString(_ dbtp: Double) -> String { String(format: "%.6f", pow(10, dbtp / 20)) }
    public static func r128Gain(_ lufs: Double) -> String { String(Int(((r128ReferenceLUFS - lufs) * 256).rounded())) }

    // (name, value) pairs for one track; album fields when album is given.
    public static func tags(track: LoudnessResult, album: AlbumLoudness?, dsd: Bool) -> [(String, String)] {
        var out: [(String, String)] = []
        if let lufs = track.integratedLUFS {
            out.append(("REPLAYGAIN_TRACK_GAIN", gainString(lufs)))
            out.append(("REPLAYGAIN_TRACK_PEAK", peakString(track.truePeakDBTP)))
            if dsd { out.append(("R128_TRACK_GAIN", r128Gain(lufs))) }
        }
        if let album, let lufs = album.integratedLUFS {
            out.append(("REPLAYGAIN_ALBUM_GAIN", gainString(lufs)))
            out.append(("REPLAYGAIN_ALBUM_PEAK", peakString(album.truePeakDBTP)))
            if dsd { out.append(("R128_ALBUM_GAIN", r128Gain(lufs))) }
        }
        if !out.isEmpty { out.append(("REPLAYGAIN_REFERENCE_LOUDNESS", String(format: "%.2f LUFS", referenceLUFS))) }
        return out
    }

    public static let fieldNames: Set<String> = [
        "REPLAYGAIN_TRACK_GAIN", "REPLAYGAIN_TRACK_PEAK", "REPLAYGAIN_ALBUM_GAIN", "REPLAYGAIN_ALBUM_PEAK",
        "REPLAYGAIN_REFERENCE_LOUDNESS", "R128_TRACK_GAIN", "R128_ALBUM_GAIN",
    ]
}
