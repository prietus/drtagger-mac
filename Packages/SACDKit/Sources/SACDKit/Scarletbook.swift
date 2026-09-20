import Foundation

// Shared Scarletbook constants and value types.
//
// On-disc facts verified on real images (2026-09-20):
//   * 2048-byte sectors, all integers big-endian.
//   * Area TOC sub-blocks are whole sectors identified by an 8-byte
//     signature: SACDTRL1 (track sectors), SACDTRL2 (track time codes),
//     SACD_IGL (ISRCs + genres), SACD_ACC (access list), SACDTTxt (track
//     texts, may span several sectors).
//   * Audio sectors: header byte = packet_info_count:3, frame_info_count:3,
//     reserved:1, dst:1. Then packet_info_count × 2 bytes
//     (frame_start:1, reserved:1, data_type:3, length:11), then
//     frame_info_count × 3 bytes (min, sec, frame) for DSD or 4 bytes for
//     DST, then the packet payloads back to back.
//   * Uncompressed stereo DSD: one 1/75 s frame is 9408 bytes (4704 per
//     channel), bytes interleaved per channel, bits MSB first.
public enum Scarletbook {
    public static let sectorSize = 2048
    public static let framesPerSecond = 75
    public static let dsd64SampleRate = 2_822_400
    public static let bytesPerChannelPerFrame = 4704       // 2822400 / 75 / 8
    public static let masterTOCSector: UInt64 = 510

    public static func sampleRate(code: Int) -> Int {
        switch code {
        case 4: return dsd64SampleRate
        default: return dsd64SampleRate
        }
    }

    public enum DataType: Int, Sendable {
        case audio = 2
        case supplementary = 3
        case padding = 7
    }

    // Track text item types (SACDTTxt).
    public enum TextType: Int, Sendable {
        case title = 1
        case performer = 2
        case songwriter = 3
        case composer = 4
        case arranger = 5
        case message = 6
        case extraMessage = 7
    }

    // Genre table for category 1 ("General"), as printed by sacd_extract
    // and the SACD spec's genre list.
    public static let genreNames: [String] = [
        "Not used", "Not defined", "Adult Contemporary", "Alternative Rock",
        "Children's Music", "Classical", "Contemporary Christian", "Country",
        "Dance", "Easy Listening", "Erotic", "Folk", "Gospel", "Hip Hop", "Jazz",
        "Latin", "Musical", "New Age", "Opera", "Operetta", "Pop Music", "RAP",
        "Reggae", "Rock Music", "Rhythm and Blues", "Sound Effects",
        "Sound Track", "Spoken Word", "World Music", "Blues",
    ]

    public static func genreName(category: Int, code: Int) -> String? {
        guard category == 1, code > 1, code < genreNames.count else { return nil }
        return genreNames[code]
    }

    // NUL-terminated text decoded per the disc's character set code
    // (1 ISO 646, 2 ISO 8859-1, 3 Shift-JIS, 7 ISO 8859-1). Unknown codes
    // try UTF-8 first.
    public static func decodeText(_ bytes: Data, charSet: Int) -> String? {
        let slice = bytes.prefix { $0 != 0 }
        guard !slice.isEmpty else { return nil }
        let data = Data(slice)
        let primary: String.Encoding
        switch charSet {
        case 2, 7: primary = .isoLatin1
        case 3: primary = .shiftJIS
        default: primary = .utf8
        }
        let text = String(data: data, encoding: primary)
            ?? String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
        return text?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func be16(_ d: Data, _ o: Int) -> UInt16 {
        let i = d.startIndex + o
        return UInt16(d[i]) << 8 | UInt16(d[i + 1])
    }

    static func be32(_ d: Data, _ o: Int) -> UInt32 {
        let i = d.startIndex + o
        return UInt32(d[i]) << 24 | UInt32(d[i + 1]) << 16 | UInt32(d[i + 2]) << 8 | UInt32(d[i + 3])
    }
}

// A position or duration in minutes:seconds:frames at 75 frames per second.
public struct SACDTime: Sendable, Equatable, Hashable, Codable, Comparable, CustomStringConvertible {
    public let totalFrames: Int

    public init(totalFrames: Int) {
        self.totalFrames = max(0, totalFrames)
    }

    public init(minutes: Int, seconds: Int, frames: Int) {
        totalFrames = (minutes * 60 + seconds) * Scarletbook.framesPerSecond + frames
    }

    public var minutes: Int { totalFrames / (60 * Scarletbook.framesPerSecond) }
    public var seconds: Int { (totalFrames / Scarletbook.framesPerSecond) % 60 }
    public var frames: Int { totalFrames % Scarletbook.framesPerSecond }
    public var totalSeconds: Double { Double(totalFrames) / Double(Scarletbook.framesPerSecond) }

    public var description: String { String(format: "%02d:%02d:%02d", minutes, seconds, frames) }

    public static func < (lhs: SACDTime, rhs: SACDTime) -> Bool { lhs.totalFrames < rhs.totalFrames }
    public static func + (lhs: SACDTime, rhs: SACDTime) -> SACDTime { SACDTime(totalFrames: lhs.totalFrames + rhs.totalFrames) }
}
