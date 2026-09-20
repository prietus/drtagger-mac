import Foundation

// STREAMINFO is the only mandatory metadata block in FLAC and is always first.
// Layout (34 bytes, big-endian, bit-packed):
//   16 bits  minimum block size (samples)
//   16 bits  maximum block size (samples)
//   24 bits  minimum frame size (bytes)
//   24 bits  maximum frame size (bytes)
//   20 bits  sample rate (Hz)
//    3 bits  channels - 1
//    5 bits  bits per sample - 1
//   36 bits  total samples
//  128 bits  MD5 signature of unencoded audio
//
// The MD5 signature is the audiophile-facing integrity check: we MUST preserve
// it byte-exact on write and we expose it so callers can verify `flac -t`-style.

public struct StreamInfo: Equatable, Sendable {
    public let minBlockSize: UInt16
    public let maxBlockSize: UInt16
    public let minFrameSize: UInt32
    public let maxFrameSize: UInt32
    public let sampleRate: UInt32
    public let channels: UInt8
    public let bitsPerSample: UInt8
    public let totalSamples: UInt64
    public let md5Signature: Data // exactly 16 bytes

    public var durationSeconds: Double {
        sampleRate == 0 ? 0 : Double(totalSamples) / Double(sampleRate)
    }

    static func parse(_ data: Data) throws(FLACError) -> StreamInfo {
        guard data.count == 34 else {
            throw .invalidMetadataBlock(reason: "STREAMINFO must be 34 bytes, got \(data.count)")
        }
        var reader = BitReader(data)
        let minBlock = UInt16(reader.read(16))
        let maxBlock = UInt16(reader.read(16))
        let minFrame = UInt32(reader.read(24))
        let maxFrame = UInt32(reader.read(24))
        let sampleRate = UInt32(reader.read(20))
        let channels = UInt8(reader.read(3) + 1)
        let bits = UInt8(reader.read(5) + 1)
        let totalSamples = reader.read(36)
        let md5 = data.subdata(in: 18..<34)
        return StreamInfo(
            minBlockSize: minBlock,
            maxBlockSize: maxBlock,
            minFrameSize: minFrame,
            maxFrameSize: maxFrame,
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bits,
            totalSamples: totalSamples,
            md5Signature: md5
        )
    }
}

// Small big-endian bit reader used only for STREAMINFO's packed fields.
// Intentionally simple; we never read past 64 bits at a time.
struct BitReader {
    private let bytes: [UInt8]
    private var bitOffset: Int = 0

    init(_ data: Data) { self.bytes = Array(data) }

    mutating func read(_ count: Int) -> UInt64 {
        var value: UInt64 = 0
        for _ in 0..<count {
            let byteIndex = bitOffset >> 3
            let bitIndex = 7 - (bitOffset & 7)
            let bit = (UInt64(bytes[byteIndex]) >> bitIndex) & 1
            value = (value << 1) | bit
            bitOffset += 1
        }
        return value
    }
}
