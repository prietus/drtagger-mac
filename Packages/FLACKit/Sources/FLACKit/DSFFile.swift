import Foundation

// DSF (Sony's DSD storage) file format. Container layout:
//
//   "DSD " chunk (28 bytes)
//     u32  "DSD "
//     u64  chunk size = 28
//     u64  total file size
//     u64  metadata pointer (file offset of ID3v2 tag, 0 if no tag)
//
//   "fmt " chunk (52 bytes)
//     u32  "fmt "
//     u64  chunk size = 52
//     u32  format version
//     u32  format ID (0 = DSD raw)
//     u32  channel type
//     u32  channel count
//     u32  sampling frequency (Hz)
//     u32  bits per sample (1 for DSD)
//     u64  sample count
//     u32  block size per channel
//     u32  reserved
//
//   "data" chunk
//     u32  "data"
//     u64  chunk size (including the 12 header bytes)
//     ...  audio frames
//
//   ID3v2 chunk (optional, at metadata pointer offset)
//     raw ID3v2 tag bytes (no chunk header)
//
// All multi-byte integers in DSF are little-endian.
//
// Tagging strategy: keep "DSD ", "fmt ", "data" verbatim, replace the
// ID3v2 trailer with a freshly-encoded one, then patch the metadata
// pointer + total file size in the DSD header. Audio frames are never
// touched.

public struct DSFFile: Sendable {
    public let sampleRate: Int
    public let bitsPerSample: Int
    public let channelCount: Int
    public let audioByteCount: UInt64
    public let sampleCount: UInt64             // total DSD samples per channel
    public let blockSizePerChannel: Int        // bytes per channel per block (typically 4096)
    public var id3Tag: ID3v2Tag?
    public let preservedFrames: [ID3v2Frame]   // APIC etc. picked up from the original tag

    // Internal layout cached for the rewriter so it doesn't have to
    // re-parse the source from scratch.
    public let dsdChunkOffset: UInt64
    public let fmtChunkOffset: UInt64
    public let dataChunkOffset: UInt64
    public let dataChunkSize: UInt64
    public let id3Offset: UInt64
    public let originalTotalSize: UInt64

    public init(source: any FLACDataSource, totalLength: UInt64? = nil) throws {
        let sourceLength = try source.length
        let total = totalLength ?? sourceLength
        guard sourceLength >= 28 else { throw FLACError.truncated }

        let dsdHeader = try source.read(at: 0, length: 28)
        guard dsdHeader[0] == 0x44, dsdHeader[1] == 0x53,
              dsdHeader[2] == 0x44, dsdHeader[3] == 0x20 else {
            throw FLACError.notAFLACFile
        }
        let dsdChunkSize = readUInt64LE(dsdHeader, at: 4)
        let totalFileSize = readUInt64LE(dsdHeader, at: 12)
        let metadataPointer = readUInt64LE(dsdHeader, at: 20)
        guard dsdChunkSize == 28 else {
            throw FLACError.invalidMetadataBlock(reason: "DSF DSD chunk size != 28")
        }

        let fmtOffset: UInt64 = 28
        guard sourceLength >= fmtOffset + 52 else { throw FLACError.truncated }
        let fmtHeader = try source.read(at: fmtOffset, length: 52)
        guard fmtHeader[0] == 0x66, fmtHeader[1] == 0x6D,
              fmtHeader[2] == 0x74, fmtHeader[3] == 0x20 else {
            throw FLACError.invalidMetadataBlock(reason: "DSF fmt chunk missing")
        }
        let fmtChunkSize = readUInt64LE(fmtHeader, at: 4)
        guard fmtChunkSize == 52 else {
            throw FLACError.invalidMetadataBlock(reason: "DSF fmt chunk size != 52")
        }
        // fmt chunk layout (offsets relative to chunk start):
        //  0-3:   "fmt " magic
        //  4-11:  chunk size (8 bytes LE) = 52
        //  12-15: format version
        //  16-19: format ID (0 = DSD raw)
        //  20-23: channel type (2 = stereo, 6 = 5.1, etc.)
        //  24-27: channel number
        //  28-31: sample rate (2822400 for DSD64)
        //  32-35: bits per sample (1 for DSD)
        //  36-43: sample count (8 bytes)
        //  44-47: block size per channel
        //  48-51: reserved
        let channelCount = Int(readUInt32LE(fmtHeader, at: 24))
        let samplingFreq = Int(readUInt32LE(fmtHeader, at: 28))
        let bitsPerSample = Int(readUInt32LE(fmtHeader, at: 32))
        let sampleCount = readUInt64LE(fmtHeader, at: 36)
        let blockSizePerChannel = Int(readUInt32LE(fmtHeader, at: 44))

        let dataOffset: UInt64 = fmtOffset + 52
        guard sourceLength >= dataOffset + 12 else { throw FLACError.truncated }
        let dataHeader = try source.read(at: dataOffset, length: 12)
        guard dataHeader[0] == 0x64, dataHeader[1] == 0x61,
              dataHeader[2] == 0x74, dataHeader[3] == 0x61 else {
            throw FLACError.invalidMetadataBlock(reason: "DSF data chunk missing")
        }
        let dataChunkSize = readUInt64LE(dataHeader, at: 4)

        // Optional ID3v2 trailer.
        var id3: ID3v2Tag?
        var preserved: [ID3v2Frame] = []
        if metadataPointer != 0, metadataPointer < sourceLength {
            // Header tells us where the tag starts; we read at most 1 MB
            // (id3 tags get fat with cover art) without locking on a
            // length we don't have authoritatively.
            let remaining = Int(min(sourceLength - metadataPointer, 16 * 1024 * 1024))
            if remaining >= 10 {
                let id3Bytes = try source.read(at: metadataPointer, length: remaining)
                if id3Bytes[0] == 0x49, id3Bytes[1] == 0x44, id3Bytes[2] == 0x33 {
                    do {
                        let parsed = try ID3v2Tag.parse(id3Bytes)
                        id3 = parsed.tag
                        preserved = parsed.tag.frames.filter { $0.id == "APIC" || $0.id == "MCDI" || $0.id == "PRIV" || $0.id == "GEOB" }
                    } catch {
                        if id3Bytes.count >= 10 {
                            let s = id3Bytes
                            let declared = (Int(s[6] & 0x7f) << 21) | (Int(s[7] & 0x7f) << 14) | (Int(s[8] & 0x7f) << 7) | Int(s[9] & 0x7f)
                            print("[DSF] ID3v2 parse error: \(error), v2.\(s[3]).\(s[4]), declared=\(declared + 10) bytes, have=\(id3Bytes.count) bytes")
                        } else {
                            print("[DSF] ID3v2 parse error: \(error), have=\(id3Bytes.count) bytes")
                        }
                    }
                } else {
                    print("[DSF] No ID3v2 magic at metadataPointer, got: \(Array(id3Bytes.prefix(4)))")
                }
            }
        }

        // For prefix-buffer parses (rare for DSF since the tag sits at
        // the end), we still record the offsets we know about so the
        // caller can decide whether to fetch more bytes.
        _ = total

        self.sampleRate = samplingFreq
        self.bitsPerSample = bitsPerSample
        self.channelCount = channelCount
        self.audioByteCount = dataChunkSize >= 12 ? dataChunkSize - 12 : 0
        self.sampleCount = sampleCount
        self.blockSizePerChannel = blockSizePerChannel
        self.id3Tag = id3
        self.preservedFrames = preserved
        self.dsdChunkOffset = 0
        self.fmtChunkOffset = fmtOffset
        self.dataChunkOffset = dataOffset
        self.dataChunkSize = dataChunkSize
        self.id3Offset = metadataPointer
        self.originalTotalSize = totalFileSize
    }

    // Rewrites the file with a fresh ID3v2 tag built from `vorbis`.
    // Audio frames are streamed straight from the source so the audio
    // payload is bit-identical. The output is a complete in-memory
    // file ready to upload via WebDAV.
    public func rewritten(with vorbis: VorbisComment, source: any FLACDataSource) throws -> Data {
        let newTag = ID3v2Bridge.toID3v23(vorbis, preserving: preservedFrames)
        let newTagBytes = newTag.encodedV23()

        // Header (28) + fmt (52) + data header (12) + audio + id3
        let preAudioSize: UInt64 = 28 + 52 + 12
        let newMetadataPointer = preAudioSize + audioByteCount
        let newTotalSize = newMetadataPointer + UInt64(newTagBytes.count)

        var output = Data()
        output.reserveCapacity(Int(newTotalSize))

        // 1) DSD header (with patched total size and metadata pointer)
        var dsdHeader = Data()
        dsdHeader.append(contentsOf: [0x44, 0x53, 0x44, 0x20]) // "DSD "
        appendUInt64LE(&dsdHeader, 28)
        appendUInt64LE(&dsdHeader, newTotalSize)
        appendUInt64LE(&dsdHeader, newMetadataPointer)
        output.append(dsdHeader)

        // 2) fmt chunk (verbatim from source)
        let fmtBytes = try source.read(at: fmtChunkOffset, length: 52)
        output.append(fmtBytes)

        // 3) data chunk header (verbatim) + audio frames
        let dataHeader = try source.read(at: dataChunkOffset, length: 12)
        output.append(dataHeader)

        // Stream the audio frames in 256 KB chunks. We keep the size
        // exactly equal to the original audio byte count so MD5s
        // computed against the audio payload still match.
        let chunkSize: Int = 256 * 1024
        var remaining = audioByteCount
        var offset = dataChunkOffset + 12
        while remaining > 0 {
            let toRead = Int(min(UInt64(chunkSize), remaining))
            let bytes = try source.read(at: offset, length: toRead)
            output.append(bytes)
            offset += UInt64(toRead)
            remaining -= UInt64(toRead)
        }

        // 4) New ID3v2 tag at metadata pointer.
        output.append(newTagBytes)

        return output
    }
}

// MARK: - Helpers

private func readUInt64LE(_ data: Data, at offset: Int) -> UInt64 {
    var v: UInt64 = 0
    for i in 0..<8 {
        v |= UInt64(data[data.startIndex + offset + i]) << (8 * i)
    }
    return v
}

private func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
    var v: UInt32 = 0
    for i in 0..<4 {
        v |= UInt32(data[data.startIndex + offset + i]) << (8 * i)
    }
    return v
}

private func appendUInt64LE(_ data: inout Data, _ value: UInt64) {
    for i in 0..<8 {
        data.append(UInt8((value >> (8 * i)) & 0xff))
    }
}
