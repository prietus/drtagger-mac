import Foundation

// Streams DSD audio into a DSF file (Sony DSF spec 1.01): "DSD " chunk,
// "fmt " chunk, "data" chunk with per-channel blocks of 4096 bytes, and an
// optional ID3v2 tag at the end referenced from the DSD chunk.
//
// Input is the SACD frame layout: bytes interleaved per channel, bits MSB
// first. DSF stores each channel in its own block and bits LSB first, so
// every byte is bit-reversed while de-interleaving. The hot loop works on
// unsafe buffers and output is written in 4 MiB batches.
public final class DSFWriter {

    public enum WriterError: LocalizedError, Equatable {
        case cannotCreate(String)
        case badChannelCount(Int)
        case misalignedInput(Int)

        public var errorDescription: String? {
            switch self {
            case .cannotCreate(let p): return "Cannot create \(p)."
            case .badChannelCount(let n): return "\(n) channels cannot be stored in DSF."
            case .misalignedInput(let n): return "Input of \(n) bytes is not a multiple of the channel count."
            }
        }
    }

    public static let blockSize = 4096
    private static let outputBatchBytes = 4 << 20

    static let bitReverse: [UInt8] = (0..<256).map { v -> UInt8 in
        var b = UInt8(v), r: UInt8 = 0
        for _ in 0..<8 {
            r = (r << 1) | (b & 1)
            b >>= 1
        }
        return r
    }

    public let url: URL
    public let channelCount: Int
    public let sampleRate: Int

    private let handle: FileHandle
    // One contiguous scratch area: channel c's current block lives at
    // c * blockSize. Flushed as a whole block group.
    private var blockGroup: UnsafeMutableBufferPointer<UInt8>
    private var fill = 0
    private var output = Data()
    private var samplesPerChannel: UInt64 = 0
    private var dataBytes: UInt64 = 0
    private var finished = false

    public init(url: URL, channelCount: Int, sampleRate: Int = Scarletbook.dsd64SampleRate) throws {
        guard (1...6).contains(channelCount) else { throw WriterError.badChannelCount(channelCount) }
        self.url = url
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let h = try? FileHandle(forWritingTo: url) else {
            throw WriterError.cannotCreate(url.path)
        }
        handle = h
        blockGroup = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: channelCount * DSFWriter.blockSize)
        blockGroup.initialize(repeating: 0)
        output.reserveCapacity(DSFWriter.outputBatchBytes + channelCount * DSFWriter.blockSize)
        // Reserve the 28 + 52 + 12 byte headers; they are rewritten in finish().
        try handle.write(contentsOf: Data(count: 92))
    }

    deinit {
        blockGroup.deallocate()
        if !finished { try? handle.close() }
    }

    // DSF channel type codes: 1 mono, 2 stereo, 3 3ch, 4 quad, 5 4ch, 6 5ch, 7 5.1ch.
    static func channelType(for count: Int) -> UInt32 {
        switch count {
        case 1: return 1
        case 2: return 2
        case 3: return 3
        case 4: return 4
        case 5: return 6
        case 6: return 7
        default: return UInt32(count)
        }
    }

    public func write(interleavedFrame data: Data) throws {
        guard !finished else { return }
        guard data.count % channelCount == 0 else { throw WriterError.misalignedInput(data.count) }
        let block = DSFWriter.blockSize
        let ch = channelCount
        var localFill = fill
        try DSFWriter.bitReverse.withUnsafeBufferPointer { table in
            try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let src = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                let dst = blockGroup.baseAddress!
                let n = raw.count
                var i = 0
                while i < n {
                    // Copy up to one block's worth of frames for every channel.
                    let framesAvailable = (n - i) / ch
                    let room = block - localFill
                    let take = min(framesAvailable, room)
                    var f = 0
                    while f < take {
                        let base = i + f * ch
                        let out = localFill + f
                        var c = 0
                        while c < ch {
                            dst[c * block + out] = table[Int(src[base + c])]
                            c += 1
                        }
                        f += 1
                    }
                    i += take * ch
                    localFill += take
                    if localFill == block {
                        fill = localFill
                        try flushBlockGroup()
                        localFill = 0
                    }
                }
            }
        }
        fill = localFill
        samplesPerChannel += UInt64(data.count / channelCount) * 8
    }

    private func flushBlockGroup() throws {
        output.append(UnsafeBufferPointer(blockGroup))
        dataBytes += UInt64(channelCount * DSFWriter.blockSize)
        fill = 0
        if output.count >= DSFWriter.outputBatchBytes {
            try handle.write(contentsOf: output)
            output.removeAll(keepingCapacity: true)
        }
    }

    // Pads the last block with zeros, writes the headers and the optional
    // ID3 tag, and closes the file. Returns samples per channel and file size.
    @discardableResult
    public func finish(id3: Data? = nil) throws -> (sampleCount: UInt64, fileSize: UInt64) {
        guard !finished else { return (samplesPerChannel, 0) }
        finished = true
        if fill > 0 {
            let block = DSFWriter.blockSize
            for c in 0..<channelCount {
                for i in fill..<block { blockGroup[c * block + i] = 0 }
            }
            try flushBlockGroup()
        }
        if !output.isEmpty {
            try handle.write(contentsOf: output)
            output.removeAll()
        }
        let dataChunkSize = 12 + dataBytes
        var id3Offset: UInt64 = 0
        var fileSize = 92 + dataBytes
        if let id3, !id3.isEmpty {
            id3Offset = fileSize
            try handle.write(contentsOf: id3)
            fileSize += UInt64(id3.count)
        }

        var header = Data()
        func u32(_ v: UInt32) { header.append(contentsOf: withUnsafeBytes(of: v.littleEndian) { Array($0) }) }
        func u64(_ v: UInt64) { header.append(contentsOf: withUnsafeBytes(of: v.littleEndian) { Array($0) }) }
        header.append(contentsOf: Array("DSD ".utf8)); u64(28); u64(fileSize); u64(id3Offset)
        header.append(contentsOf: Array("fmt ".utf8)); u64(52); u32(1); u32(0)
        u32(DSFWriter.channelType(for: channelCount)); u32(UInt32(channelCount)); u32(UInt32(sampleRate)); u32(1)
        u64(samplesPerChannel); u32(UInt32(DSFWriter.blockSize)); u32(0)
        header.append(contentsOf: Array("data".utf8)); u64(dataChunkSize)
        precondition(header.count == 92)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: header)
        try handle.close()
        return (samplesPerChannel, fileSize)
    }
}
