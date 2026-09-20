import Foundation

// Minimal Scarletbook reader: enough of the master TOC, master text and
// area TOCs to recognise a SACD ISO and describe it (areas, track counts,
// DST, disc title/artist). Track extraction lives in ImageKit (phase 3).
//
// Layout verified against 205 real ISOs (2026-09-20). Sectors are 2048
// bytes; all integers are big-endian.
//   sector 510  master TOC   "SACDMTOC"
//   sector 511  master text  "SACDText"
//   master TOC  +64 area 1 TOC start, +72 area 2 TOC start (sector numbers)
//   area TOC    +21 frame format (0 DST, 2/3 DSD), +32 channels,
//               +64 play time (min, sec, frames), +68 track offset,
//               +69 track count, +72/+76 track start/end sectors
public struct SACDInfo: Sendable, Equatable, Codable, Hashable {

    public enum FrameFormat: String, Sendable, Codable {
        case dst
        case dsd
        case unknown
    }

    public struct Area: Sendable, Equatable, Codable, Hashable {
        public let isMultichannel: Bool
        public let frameFormat: FrameFormat
        public let channelCount: Int
        public let trackOffset: Int
        public let trackCount: Int
        public let playTimeSeconds: Int
        public let tocSector: UInt32
        public let trackStartSector: UInt32
        public let trackEndSector: UInt32

        public var isDST: Bool { frameFormat == .dst }
    }

    public let albumSetSize: Int
    public let albumSequenceNumber: Int
    public let albumCatalogNumber: String
    public let discCatalogNumber: String
    public let discDate: String?          // "YYYY-MM-DD" when the disc carries one
    public let localeLanguage: String     // e.g. "en", "ja"
    public let characterSetCode: Int
    public let albumTitle: String?
    public let albumArtist: String?
    public let discTitle: String?
    public let discArtist: String?
    public let areas: [Area]

    public var stereoArea: Area? { areas.first { !$0.isMultichannel } }
    public var multichannelArea: Area? { areas.first { $0.isMultichannel } }
    public var hasDST: Bool { areas.contains { $0.isDST } }
    public var trackCount: Int { stereoArea?.trackCount ?? areas.first?.trackCount ?? 0 }

    // Prefer the disc-level text, fall back to the album-level text.
    public var title: String? { nonEmpty(discTitle) ?? nonEmpty(albumTitle) }
    public var artist: String? { nonEmpty(discArtist) ?? nonEmpty(albumArtist) }

    private func nonEmpty(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}

public enum SACDProbe {

    public static let sectorSize = 2048
    public static let masterTOCSector: UInt64 = 510

    public enum ProbeError: LocalizedError, Equatable {
        case notSACD
        case truncated
        case badAreaTOC(UInt32)

        public var errorDescription: String? {
            switch self {
            case .notSACD: return "Not a SACD image (no Scarletbook master TOC)."
            case .truncated: return "The image is shorter than a SACD master TOC."
            case .badAreaTOC(let s): return "Area TOC at sector \(s) is not readable."
            }
        }
    }

    // Cheap check: only the master TOC sector is read.
    public static func isSACD(url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? read(handle, sector: masterTOCSector) else { return false }
        return data.count >= 8 && data.prefix(8) == Data("SACDMTOC".utf8)
    }

    public static func probe(url: URL) throws -> SACDInfo {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let master = try read(handle, sector: masterTOCSector)
        guard master.count == sectorSize else { throw ProbeError.truncated }
        guard master.prefix(8) == Data("SACDMTOC".utf8) else { throw ProbeError.notSACD }

        let albumSetSize = Int(be16(master, 16))
        let albumSequence = Int(be16(master, 18))
        let albumCatalog = asciiField(master, 24, 16)
        let discCatalog = asciiField(master, 88, 16)

        let year = Int(be16(master, 120))
        let month = Int(master[122])
        let day = Int(master[123])
        let discDate: String? = year > 0 ? String(format: "%04d-%02d-%02d", year, max(1, month), max(1, day)) : nil

        let language = asciiField(master, 136, 2)
        let charSet = Int(master[138])

        // Master text (sector 511). Positions are offsets within the sector.
        var albumTitle: String? = nil, albumArtist: String? = nil
        var discTitle: String? = nil, discArtist: String? = nil
        if let text = try? read(handle, sector: masterTOCSector + 1),
           text.count == sectorSize, text.prefix(8) == Data("SACDText".utf8) {
            albumTitle = cString(text, at: Int(be16(text, 16)), charSet: charSet)
            albumArtist = cString(text, at: Int(be16(text, 18)), charSet: charSet)
            discTitle = cString(text, at: Int(be16(text, 32)), charSet: charSet)
            discArtist = cString(text, at: Int(be16(text, 34)), charSet: charSet)
        }

        var areas: [SACDInfo.Area] = []
        for (offset, _) in [(64, false), (72, true)] {
            let start = be32(master, offset)
            guard start != 0 else { continue }
            let toc = try read(handle, sector: UInt64(start))
            guard toc.count == sectorSize else { throw ProbeError.badAreaTOC(start) }
            let id = String(decoding: toc.prefix(8), as: UTF8.self)
            guard id == "TWOCHTOC" || id == "MULCHTOC" else { throw ProbeError.badAreaTOC(start) }
            let format: SACDInfo.FrameFormat
            switch toc[21] {
            case 0: format = .dst
            case 2, 3: format = .dsd
            default: format = .unknown
            }
            let minutes = Int(toc[64]), seconds = Int(toc[65])
            areas.append(SACDInfo.Area(
                isMultichannel: id == "MULCHTOC",
                frameFormat: format,
                channelCount: Int(toc[32]),
                trackOffset: Int(toc[68]),
                trackCount: Int(toc[69]),
                playTimeSeconds: minutes * 60 + seconds,
                tocSector: start,
                trackStartSector: be32(toc, 72),
                trackEndSector: be32(toc, 76)
            ))
        }

        return SACDInfo(
            albumSetSize: albumSetSize,
            albumSequenceNumber: albumSequence,
            albumCatalogNumber: albumCatalog,
            discCatalogNumber: discCatalog,
            discDate: discDate,
            localeLanguage: language,
            characterSetCode: charSet,
            albumTitle: albumTitle,
            albumArtist: albumArtist,
            discTitle: discTitle,
            discArtist: discArtist,
            areas: areas
        )
    }

    // MARK: - Helpers

    private static func read(_ handle: FileHandle, sector: UInt64) throws -> Data {
        try handle.seek(toOffset: sector * UInt64(sectorSize))
        return try handle.read(upToCount: sectorSize) ?? Data()
    }

    static func be16(_ d: Data, _ o: Int) -> UInt16 {
        let i = d.startIndex + o
        return UInt16(d[i]) << 8 | UInt16(d[i + 1])
    }

    static func be32(_ d: Data, _ o: Int) -> UInt32 {
        let i = d.startIndex + o
        return UInt32(d[i]) << 24 | UInt32(d[i + 1]) << 16 | UInt32(d[i + 2]) << 8 | UInt32(d[i + 3])
    }

    static func asciiField(_ d: Data, _ o: Int, _ len: Int) -> String {
        let i = d.startIndex + o
        let slice = d[i..<(i + len)].prefix { $0 != 0 }
        return String(decoding: slice, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    // NUL-terminated string at `pos`, decoded per the disc's character set
    // code (1 ISO 646, 2 ISO 8859-1, 3 Shift-JIS, 7 ISO 8859-1). Unknown
    // codes try UTF-8 then Latin-1.
    static func cString(_ d: Data, at pos: Int, charSet: Int) -> String? {
        guard pos > 0, pos < d.count else { return nil }
        let start = d.startIndex + pos
        let bytes = d[start...].prefix { $0 != 0 }
        guard !bytes.isEmpty else { return nil }
        let data = Data(bytes)
        let encoding: String.Encoding
        switch charSet {
        case 2, 7: encoding = .isoLatin1
        case 3: encoding = .shiftJIS
        default: encoding = .utf8
        }
        if let s = String(data: data, encoding: encoding) { return s }
        if let s = String(data: data, encoding: .utf8) { return s }
        return String(data: data, encoding: .isoLatin1)
    }
}
