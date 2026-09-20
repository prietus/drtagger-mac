import Foundation

// WAV (RIFF) file format. Top-level layout:
//
//   "RIFF" (4)
//   u32    file size minus 8        (little-endian)
//   "WAVE" (4)
//   chunks
//
// Each chunk:
//   id     (4 bytes ASCII)
//   u32    chunk size (LE, excludes the 8-byte chunk header)
//   bytes  payload
//   pad    one zero byte if size is odd
//
// Chunks we care about:
//   "fmt "  PCM format (sample rate / bits / channels)
//   "data"  audio
//   "id3 "  or "ID3 "  ID3v2 tag (the modern WAV tag)
//   "LIST"  with "INFO" subchunks (legacy text tags) — read-only fallback
//
// Tagging strategy: enumerate chunks, drop any existing "id3 " / "ID3 "
// chunk, append a freshly-built one at the end, fix the RIFF size. We
// preserve everything else byte-for-byte, including the "data" chunk
// (audio) and any LIST/bext/cue blocks.

public struct WAVFile: Sendable {
    public let sampleRate: Int
    public let bitsPerSample: Int
    public let channelCount: Int
    public var id3Tag: ID3v2Tag?
    public let preservedFrames: [ID3v2Frame]

    // Cached chunk layout for the rewriter.
    let chunks: [WAVChunk]
    private let totalSize: UInt64

    public struct WAVChunk: Sendable {
        public let id: String
        public let offset: UInt64       // file offset of the chunk header (id+size)
        public let size: UInt64         // payload size from the chunk header
        public let paddedSize: UInt64   // size + 1 if odd, else size
    }

    public init(source: any FLACDataSource, totalLength: UInt64? = nil) throws {
        let sourceLength = try source.length
        let total = totalLength ?? sourceLength
        guard sourceLength >= 12 else { throw FLACError.truncated }

        let riffHeader = try source.read(at: 0, length: 12)
        guard riffHeader[0] == 0x52, riffHeader[1] == 0x49,
              riffHeader[2] == 0x46, riffHeader[3] == 0x46 else {
            throw FLACError.notAFLACFile
        }
        guard riffHeader[8] == 0x57, riffHeader[9] == 0x41,
              riffHeader[10] == 0x56, riffHeader[11] == 0x45 else {
            throw FLACError.invalidMetadataBlock(reason: "WAV missing WAVE marker")
        }

        var chunks: [WAVChunk] = []
        var cursor: UInt64 = 12
        while cursor + 8 <= sourceLength {
            let header = try source.read(at: cursor, length: 8)
            guard let id = String(data: Data(header.prefix(4)), encoding: .ascii) else { break }
            let size = UInt64(readUInt32LE(header, at: 4))
            let padded = size + (size % 2)
            let chunk = WAVChunk(id: id, offset: cursor, size: size, paddedSize: padded)
            chunks.append(chunk)
            cursor += 8 + padded
            if cursor > sourceLength {
                // Last chunk may extend past the source for prefix-buffer
                // reads of huge audio. Stop without throwing.
                break
            }
        }

        // Parse the fmt chunk for sample rate / bits.
        var sampleRate = 0
        var bitsPerSample = 0
        var channelCount = 0
        if let fmt = chunks.first(where: { $0.id == "fmt " }) {
            let fmtBytes = try source.read(at: fmt.offset + 8, length: Int(min(fmt.size, 40)))
            // PCM fmt layout (we ignore extension fields):
            //   u16  audio format
            //   u16  channels
            //   u32  sample rate
            //   u32  byte rate
            //   u16  block align
            //   u16  bits per sample
            channelCount = Int(readUInt16LE(fmtBytes, at: 2))
            sampleRate = Int(readUInt32LE(fmtBytes, at: 4))
            bitsPerSample = Int(readUInt16LE(fmtBytes, at: 14))
        }

        // Parse the ID3 chunk if present. Some taggers write "id3 ",
        // some write "ID3 " — accept both.
        var id3: ID3v2Tag?
        var preserved: [ID3v2Frame] = []
        if let id3Chunk = chunks.first(where: { $0.id == "id3 " || $0.id == "ID3 " }) {
            let payload = try source.read(at: id3Chunk.offset + 8, length: Int(id3Chunk.size))
            if payload.count >= 10,
               payload[0] == 0x49, payload[1] == 0x44, payload[2] == 0x33,
               let parsed = try? ID3v2Tag.parse(payload) {
                id3 = parsed.tag
                preserved = parsed.tag.frames.filter { $0.id == "APIC" || $0.id == "MCDI" || $0.id == "PRIV" || $0.id == "GEOB" }
            }
        }

        _ = total

        self.sampleRate = sampleRate
        self.bitsPerSample = bitsPerSample
        self.channelCount = channelCount
        self.chunks = chunks
        self.id3Tag = id3
        self.preservedFrames = preserved
        self.totalSize = sourceLength
    }

    // Rewrites the WAV with a fresh ID3 chunk built from `vorbis`.
    // Strategy:
    //   1) Re-emit the RIFF/WAVE header with a placeholder size.
    //   2) Stream every chunk EXCEPT existing id3/ID3 chunks unchanged.
    //   3) Append the new "id3 " chunk at the end.
    //   4) Patch the RIFF size now that we know the final length.
    public func rewritten(with vorbis: VorbisComment, source: any FLACDataSource) throws -> Data {
        let newTag = ID3v2Bridge.toID3v23(vorbis, preserving: preservedFrames)
        let newTagBytes = newTag.encodedV23()
        // ID3 chunk payload must be even-aligned in the WAV stream.
        let id3PayloadPaddingNeeded = newTagBytes.count % 2 != 0

        var output = Data()
        // RIFF + size placeholder + WAVE
        output.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        output.append(contentsOf: [0, 0, 0, 0])
        output.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"

        // Stream original chunks except any existing ID3 ones.
        for chunk in chunks {
            if chunk.id == "id3 " || chunk.id == "ID3 " { continue }
            // Read header + padded payload from source.
            let bytes = try source.read(
                at: chunk.offset,
                length: Int(8 + chunk.paddedSize)
            )
            output.append(bytes)
        }

        // Append the new ID3 chunk.
        output.append(contentsOf: [0x69, 0x64, 0x33, 0x20]) // "id3 "
        var sizeLE = UInt32(newTagBytes.count).littleEndian
        withUnsafeBytes(of: &sizeLE) { output.append(contentsOf: $0) }
        output.append(newTagBytes)
        if id3PayloadPaddingNeeded {
            output.append(0)
        }

        // Patch the RIFF size: total file size minus 8.
        let riffSize = UInt32(output.count - 8).littleEndian
        var sizeBytes = [UInt8](repeating: 0, count: 4)
        withUnsafeBytes(of: riffSize) { src in
            for i in 0..<4 { sizeBytes[i] = src[i] }
        }
        for i in 0..<4 {
            output[4 + i] = sizeBytes[i]
        }

        return output
    }
}

// MARK: - Helpers

private func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
    var v: UInt32 = 0
    for i in 0..<4 {
        v |= UInt32(data[data.startIndex + offset + i]) << (8 * i)
    }
    return v
}

private func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
    var v: UInt16 = 0
    v |= UInt16(data[data.startIndex + offset]) << 0
    v |= UInt16(data[data.startIndex + offset + 1]) << 8
    return v
}
