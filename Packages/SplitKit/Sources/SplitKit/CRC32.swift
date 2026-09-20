import Foundation

// Standard CRC-32 (IEEE 802.3, reflected, polynomial 0xEDB88320), the same
// value zlib's crc32() and CUETools produce. Table-driven, byte at a time,
// fast enough for a CD image per second on Apple silicon.
public struct CRC32: Sendable {

    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    private var state: UInt32 = 0xFFFF_FFFF

    public init() {}

    public mutating func update(_ data: Data) {
        data.withUnsafeBytes { update(bytes: $0) }
    }

    public mutating func update(bytes: UnsafeRawBufferPointer) {
        var c = state
        let table = Self.table
        for b in bytes {
            c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8)
        }
        state = c
    }

    public var value: UInt32 { state ^ 0xFFFF_FFFF }

    public static func checksum(_ data: Data) -> UInt32 {
        var crc = CRC32()
        crc.update(data)
        return crc.value
    }

    // CRC of a byte range of a file, read in chunks.
    public static func checksum(fileAt url: URL, range: Range<Int64>, chunkSize: Int = 4 << 20) throws -> UInt32 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(range.lowerBound))
        var remaining = range.upperBound - range.lowerBound
        var crc = CRC32()
        while remaining > 0 {
            let n = Int(min(Int64(chunkSize), remaining))
            guard let chunk = try handle.read(upToCount: n), !chunk.isEmpty else { break }
            crc.update(chunk)
            remaining -= Int64(chunk.count)
        }
        return crc.value
    }
}

extension UInt32 {
    public var hex8: String { String(format: "%08x", self) }
}
