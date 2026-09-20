import Foundation
import LibraryKit

public struct SACDTrack: Sendable, Equatable, Hashable, Codable {
    public let number: Int                // 1-based within the area
    public let startSector: UInt32
    public let lengthSectors: UInt32
    public let startTime: SACDTime
    public let duration: SACDTime
    public var title: String?
    public var performer: String?
    public var songwriter: String?
    public var composer: String?
    public var arranger: String?
    public var message: String?
    public var isrc: String?
    public var genre: String?

    public init(number: Int, startSector: UInt32, lengthSectors: UInt32, startTime: SACDTime, duration: SACDTime) {
        self.number = number
        self.startSector = startSector
        self.lengthSectors = lengthSectors
        self.startTime = startTime
        self.duration = duration
    }

    public var endTime: SACDTime { startTime + duration }
}

public struct SACDArea: Sendable, Equatable, Hashable, Codable {
    public let isMultichannel: Bool
    public let frameFormat: SACDInfo.FrameFormat
    public let channelCount: Int
    public let sampleRate: Int
    public let tocSector: UInt32
    public let tocSizeSectors: Int
    public let audioStartSector: UInt32
    public let audioEndSector: UInt32     // last audio sector (inclusive)
    public let trackOffset: Int
    public let playTime: SACDTime
    public let characterSetCode: Int
    public var tracks: [SACDTrack]

    public var isDST: Bool { frameFormat == .dst }
    public var trackCount: Int { tracks.count }
    // Uncompressed DSD frame size for this area's channel count.
    public var dsdFrameBytes: Int { channelCount * Scarletbook.bytesPerChannelPerFrame }
    public var displayName: String { isMultichannel ? "Multichannel (\(channelCount) ch)" : "Stereo" }
}

public struct SACDDisc: Sendable, Equatable, Codable {
    public let url: URL
    public let info: SACDInfo
    public let areas: [SACDArea]

    public var stereoArea: SACDArea? { areas.first { !$0.isMultichannel } }
    public var multichannelArea: SACDArea? { areas.first { $0.isMultichannel } }
    public var title: String? { info.title }
    public var artist: String? { info.artist }
    public var year: String? { info.discDate.map { String($0.prefix(4)) } }
    public var genre: String? {
        // Master TOC carries album and disc genre tables; the reader stores
        // the first named one on every track that has none of its own.
        areas.first?.tracks.first?.genre
    }
}

public enum SACDDiscReader {

    public enum ReadError: LocalizedError, Equatable {
        case notSACD
        case badAreaTOC(UInt32)
        case missingTrackLists(UInt32)

        public var errorDescription: String? {
            switch self {
            case .notSACD: return "Not a SACD image."
            case .badAreaTOC(let s): return "Area TOC at sector \(s) is not readable."
            case .missingTrackLists(let s): return "Area at sector \(s) has no track list."
            }
        }
    }

    public static func read(url: URL) throws -> SACDDisc {
        let info = try SACDProbe.probe(url: url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let master = try sector(handle, Scarletbook.masterTOCSector)
        let masterGenre = genreFromTable(master, at: 104) ?? genreFromTable(master, at: 40)

        var areas: [SACDArea] = []
        for probeArea in info.areas {
            areas.append(try readArea(handle, start: probeArea.tocSector, isMultichannel: probeArea.isMultichannel,
                                      masterCharSet: info.characterSetCode, fallbackGenre: masterGenre))
        }
        return SACDDisc(url: url, info: info, areas: areas)
    }

    // MARK: - Area

    private static func readArea(_ handle: FileHandle, start: UInt32, isMultichannel: Bool, masterCharSet: Int, fallbackGenre: String?) throws -> SACDArea {
        let toc = try sector(handle, UInt64(start))
        let id = String(decoding: toc.prefix(8), as: UTF8.self)
        guard id == "TWOCHTOC" || id == "MULCHTOC" else { throw ReadError.badAreaTOC(start) }

        let size = Int(Scarletbook.be16(toc, 10))
        let format: SACDInfo.FrameFormat
        switch toc[21] {
        case 0: format = .dst
        case 2, 3: format = .dsd
        default: format = .unknown
        }
        let channels = Int(toc[32])
        let trackOffset = Int(toc[68])
        let trackCount = Int(toc[69])
        let audioStart = Scarletbook.be32(toc, 72)
        let audioEnd = Scarletbook.be32(toc, 76)
        let playTime = SACDTime(minutes: Int(toc[64]), seconds: Int(toc[65]), frames: Int(toc[66]))
        let areaCharSet = Int(toc[90]) != 0 ? Int(toc[90]) : masterCharSet

        // Sub-blocks by signature.
        var trl1: Data? = nil, trl2: Data? = nil, igl: Data? = nil
        var textStart: Int? = nil
        var sectors: [Data] = []
        for i in 1..<max(1, size) {
            let s = try sector(handle, UInt64(start) + UInt64(i))
            sectors.append(s)
            switch String(decoding: s.prefix(8), as: UTF8.self) {
            case "SACDTRL1": trl1 = s
            case "SACDTRL2": trl2 = s
            case "SACD_IGL": igl = try sector(handle, UInt64(start) + UInt64(i)) + (i + 1 < size ? try sector(handle, UInt64(start) + UInt64(i) + 1) : Data())
            case "SACDTTxt": textStart = i - 1
            default: break
            }
        }
        guard let trl1, let trl2 else { throw ReadError.missingTrackLists(start) }

        var tracks: [SACDTrack] = []
        for k in 0..<trackCount {
            let startSector = Scarletbook.be32(trl1, 8 + 4 * k)
            let length = Scarletbook.be32(trl1, 8 + 1020 + 4 * k)
            let st = trl2[trl2.startIndex + 8 + 4 * k ..< trl2.startIndex + 12 + 4 * k]
            let du = trl2[trl2.startIndex + 8 + 1020 + 4 * k ..< trl2.startIndex + 12 + 1020 + 4 * k]
            var track = SACDTrack(
                number: k + 1,
                startSector: startSector,
                lengthSectors: length,
                startTime: SACDTime(minutes: Int(st[st.startIndex]), seconds: Int(st[st.startIndex + 1]), frames: Int(st[st.startIndex + 2])),
                duration: SACDTime(minutes: Int(du[du.startIndex]), seconds: Int(du[du.startIndex + 1]), frames: Int(du[du.startIndex + 2]))
            )
            if let igl {
                let isrcBytes = igl[igl.startIndex + 8 + 12 * k ..< igl.startIndex + 20 + 12 * k]
                if let isrc = Scarletbook.decodeText(Data(isrcBytes) + Data([0]), charSet: 1), isrc.count == 12 {
                    track.isrc = isrc
                }
                let g = 8 + 3060 + 4 * k
                if g + 4 <= igl.count {
                    let category = Int(igl[igl.startIndex + g])
                    let code = Int(Scarletbook.be16(igl, g + 2))
                    track.genre = Scarletbook.genreName(category: category, code: code)
                }
            }
            if track.genre == nil { track.genre = fallbackGenre }
            tracks.append(track)
        }

        if let textStart {
            let block = sectors[textStart...].reduce(Data(), +)
            applyTexts(block, to: &tracks, charSet: areaCharSet)
        }

        return SACDArea(
            isMultichannel: isMultichannel,
            frameFormat: format,
            channelCount: channels,
            sampleRate: Scarletbook.sampleRate(code: Int(toc[20])),
            tocSector: start,
            tocSizeSectors: size,
            audioStartSector: audioStart,
            audioEndSector: audioEnd,
            trackOffset: trackOffset,
            playTime: playTime,
            characterSetCode: areaCharSet,
            tracks: tracks
        )
    }

    // SACDTTxt: u16 position per track (relative to the block), then at each
    // position: item count (u8) + 3 reserved bytes, then items of
    // {type u8, reserved u8, NUL-terminated text} padded to 4 bytes.
    private static func applyTexts(_ block: Data, to tracks: inout [SACDTrack], charSet: Int) {
        for k in tracks.indices {
            let pos = Int(Scarletbook.be16(block, 8 + 2 * k))
            guard pos >= 12, pos + 4 <= block.count else { continue }
            let count = Int(block[block.startIndex + pos])
            var p = pos + 4
            for _ in 0..<min(count, 16) {
                guard p + 2 < block.count else { break }
                let type = Int(block[block.startIndex + p])
                let textStart = p + 2
                let rest = block[(block.startIndex + textStart)...]
                let text = Scarletbook.decodeText(Data(rest.prefix(512)), charSet: charSet)
                let nulOffset = rest.firstIndex(of: 0).map { $0 - rest.startIndex } ?? rest.count
                switch Scarletbook.TextType(rawValue: type) {
                case .title: tracks[k].title = text
                case .performer: tracks[k].performer = text
                case .songwriter: tracks[k].songwriter = text
                case .composer: tracks[k].composer = text
                case .arranger: tracks[k].arranger = text
                case .message: tracks[k].message = text
                default: break
                }
                var next = textStart + nulOffset + 1
                next = (next + 3) & ~3
                p = next
            }
        }
    }

    private static func genreFromTable(_ master: Data, at offset: Int) -> String? {
        for i in 0..<4 {
            let category = Int(master[master.startIndex + offset + 4 * i])
            let code = Int(Scarletbook.be16(master, offset + 4 * i + 2))
            if let name = Scarletbook.genreName(category: category, code: code) { return name }
        }
        return nil
    }

    static func sector(_ handle: FileHandle, _ n: UInt64) throws -> Data {
        try handle.seek(toOffset: n * UInt64(Scarletbook.sectorSize))
        let d = try handle.read(upToCount: Scarletbook.sectorSize) ?? Data()
        guard d.count == Scarletbook.sectorSize else { throw ReadError.notSACD }
        return d
    }
}
