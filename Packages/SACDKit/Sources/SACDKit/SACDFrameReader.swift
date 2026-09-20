import Foundation

// One audio frame (1/75 s) as stored on the disc: raw DSD bytes interleaved
// per channel with MSB-first bits, or a DST-compressed frame.
public struct SACDFrame: Sendable, Equatable {
    public let timecode: SACDTime
    public let data: Data

    public init(timecode: SACDTime, data: Data) {
        self.timecode = timecode
        self.data = data
    }
}

// Parses the packet structure of one audio sector.
struct AudioSector {
    struct Packet {
        let frameStart: Bool
        let dataType: Int
        let range: Range<Int>       // payload byte range within the sector
    }

    let isDST: Bool
    let packets: [Packet]
    let frameTimecodes: [SACDTime]

    enum ParseError: LocalizedError, Equatable {
        case malformed(sector: UInt64, reason: String)

        var errorDescription: String? {
            switch self {
            case .malformed(let s, let r): return "Audio sector \(s) is malformed: \(r)."
            }
        }
    }

    init(_ sector: Data, number: UInt64) throws {
        let base = sector.startIndex
        let header = sector[base]
        let packetCount = Int(header >> 5) & 0x7
        let frameCount = Int(header >> 2) & 0x7
        isDST = (header & 0x1) != 0

        var offset = 1
        var lengths: [(Bool, Int, Int)] = []
        for _ in 0..<packetCount {
            guard offset + 2 <= sector.count else { throw ParseError.malformed(sector: number, reason: "packet table truncated") }
            let word = Int(sector[base + offset]) << 8 | Int(sector[base + offset + 1])
            offset += 2
            lengths.append(((word >> 15) & 1 == 1, (word >> 11) & 0x7, word & 0x7FF))
        }
        let infoSize = isDST ? 4 : 3
        var timecodes: [SACDTime] = []
        for _ in 0..<frameCount {
            guard offset + infoSize <= sector.count else { throw ParseError.malformed(sector: number, reason: "frame table truncated") }
            timecodes.append(SACDTime(minutes: Int(sector[base + offset]), seconds: Int(sector[base + offset + 1]), frames: Int(sector[base + offset + 2])))
            offset += infoSize
        }
        var packets: [Packet] = []
        packets.reserveCapacity(packetCount)
        for (start, type, length) in lengths {
            guard offset + length <= sector.count else { throw ParseError.malformed(sector: number, reason: "packet runs past the sector") }
            packets.append(Packet(frameStart: start, dataType: type, range: offset..<(offset + length)))
            offset += length
        }
        self.packets = packets
        self.frameTimecodes = timecodes
    }
}

// Sequential reader that reassembles frames from an area's audio sectors.
// A frame begins with a packet flagged frame_start and continues through
// following audio packets (possibly in later sectors) until the next
// frame_start. Not thread-safe; owned by the extractor actor.
public final class SACDFrameReader {

    public enum ReaderError: LocalizedError, Equatable {
        case cannotOpen(String)
        case truncated(sector: UInt64)

        public var errorDescription: String? {
            switch self {
            case .cannotOpen(let p): return "Cannot open \(p)."
            case .truncated(let s): return "Image ends before sector \(s)."
            }
        }
    }

    private let handle: FileHandle
    private let endSector: UInt64
    private var nextSector: UInt64
    private var buffer = Data()
    private var bufferFirstSector: UInt64 = 0
    private var current: (timecode: SACDTime, data: Data)?
    private var queue: [SACDFrame] = []
    private var exhausted = false
    private let sectorsPerRead = 512

    public private(set) var sectorsRead: UInt64 = 0
    public let totalSectors: UInt64

    public init(url: URL, firstSector: UInt32, lastSector: UInt32) throws {
        guard let h = try? FileHandle(forReadingFrom: url) else { throw ReaderError.cannotOpen(url.path) }
        handle = h
        nextSector = UInt64(firstSector)
        endSector = UInt64(lastSector)
        totalSectors = UInt64(lastSector) >= UInt64(firstSector) ? UInt64(lastSector) - UInt64(firstSector) + 1 : 0
    }

    deinit {
        try? handle.close()
    }

    // Returns the next complete frame, or nil after the last sector.
    public func next() throws -> SACDFrame? {
        while queue.isEmpty {
            if exhausted { return nil }
            guard let sector = try readSector() else {
                exhausted = true
                if let c = current {
                    current = nil
                    queue.append(SACDFrame(timecode: c.timecode, data: c.data))
                }
                continue
            }
            let parsed = try AudioSector(sector, number: nextSector - 1)
            var frameIndex = 0
            for packet in parsed.packets where packet.dataType == Scarletbook.DataType.audio.rawValue {
                if packet.frameStart {
                    if let c = current {
                        queue.append(SACDFrame(timecode: c.timecode, data: c.data))
                    }
                    let tc = frameIndex < parsed.frameTimecodes.count ? parsed.frameTimecodes[frameIndex] : SACDTime(totalFrames: 0)
                    frameIndex += 1
                    var d = Data()
                    d.reserveCapacity(16384)
                    current = (tc, d)
                }
                if current != nil {
                    current!.data.append(sector[sector.startIndex + packet.range.lowerBound ..< sector.startIndex + packet.range.upperBound])
                }
            }
        }
        return queue.removeFirst()
    }

    private func readSector() throws -> Data? {
        guard nextSector <= endSector else { return nil }
        let inBuffer = nextSector >= bufferFirstSector && Int(nextSector - bufferFirstSector + 1) * Scarletbook.sectorSize <= buffer.count
        if !inBuffer {
            let count = Int(min(UInt64(sectorsPerRead), endSector - nextSector + 1))
            try handle.seek(toOffset: nextSector * UInt64(Scarletbook.sectorSize))
            buffer = try handle.read(upToCount: count * Scarletbook.sectorSize) ?? Data()
            bufferFirstSector = nextSector
            guard buffer.count >= Scarletbook.sectorSize else { throw ReaderError.truncated(sector: nextSector) }
        }
        let start = Int(nextSector - bufferFirstSector) * Scarletbook.sectorSize
        let sector = buffer[buffer.startIndex + start ..< buffer.startIndex + start + Scarletbook.sectorSize]
        nextSector += 1
        sectorsRead += 1
        return sector
    }
}
