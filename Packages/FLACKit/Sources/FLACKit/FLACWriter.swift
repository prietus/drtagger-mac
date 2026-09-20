import Foundation

// Write strategy, ported from dr_mobile/DrMobile/Sources/Services/
// FlacTagWriter.swift (lines 150-202) with the optimization we noted in the
// reference memory: if the existing PADDING can absorb the new VORBIS_COMMENT
// without changing the total metadata section length, we rewrite only the
// metadata prefix and skip copying the audio frames entirely. That matters
// for huge files edited in place on a fast local disk.
//
// The standard path is always available as a fallback and is what we use
// for writes that land on a NAS (where the whole file is going back over
// the wire anyway, so in-place vs full-rewrite is irrelevant).

public enum FLACWriteStrategy: Sendable, Equatable {
    /// Rebuild the file entirely. Audio frames are copied byte-exact.
    case fullRewrite
    /// Overwrite only the metadata prefix (header + blocks). Only valid when
    /// the new metadata section length equals the original.
    case metadataPrefixOnly
}

public struct FLACWriteResult: Sendable, Equatable {
    public let strategy: FLACWriteStrategy
    public let newMetadataLength: Int
    public let audioBytesPreserved: UInt64
}

extension FLACFile {

    /// Produces the raw bytes of a FLAC file whose metadata section has been
    /// replaced with `tags`. The audio frames are copied from `source`
    /// byte-exact, so STREAMINFO's MD5 signature remains valid.
    ///
    /// - Parameters:
    ///   - tags: the vorbis comment to write
    ///   - source: the original file's data source (needed for audio frames
    ///             and for any metadata blocks that were stored as references
    ///             rather than inlined during parsing)
    public func rewritten(with tags: VorbisComment, source: any FLACDataSource) throws -> Data {
        var out = Data()
        out.append(contentsOf: [0x66, 0x4C, 0x61, 0x43]) // "fLaC"

        let newBlocks = try rebuiltBlocks(with: tags, source: source)
        for (i, block) in newBlocks.enumerated() {
            let isLast = i == newBlocks.count - 1
            out.append(encodeBlockHeader(type: block.type, isLast: isLast, length: block.payload.count))
            out.append(block.payload)
        }

        // Stream audio frames from the source in chunks so we don't balloon
        // memory on large files. 1 MiB chunks balance syscall count against
        // peak memory; tunable if profiling says otherwise.
        let chunkSize: Int = 1 * 1024 * 1024
        var remaining = audioFrameLength
        var readCursor = audioFrameOffset
        while remaining > 0 {
            let take = Int(min(UInt64(chunkSize), remaining))
            let data = try source.read(at: readCursor, length: take)
            out.append(data)
            readCursor += UInt64(take)
            remaining -= UInt64(take)
        }
        return out
    }

    // Resolves references, drops PADDING and VORBIS_COMMENT, and rebuilds
    // the metadata section in an order that's friendly to prefix-buffer
    // parsers (WebDAV range reads, etc.):
    //
    //   STREAMINFO  → small preserved blocks (SEEKTABLE, CUESHEET, APPLICATION)
    //   → VORBIS_COMMENT → PADDING (4 KiB) → PICTURE blocks at the very end
    //
    // Putting PICTURE last is the audiophile convention (libFLAC defaults
    // to it, XLD and dBpoweramp follow it) and it's what keeps a 64 KiB
    // prefetch sufficient for tag-only parsing. With PICTURE in the middle,
    // a single embedded cover of 150 KiB pushes the VORBIS_COMMENT block
    // outside the prefetch window and breaks fast browse on NAS.
    private func rebuiltBlocks(
        with tags: VorbisComment,
        source: any FLACDataSource
    ) throws -> [(type: MetadataBlock.BlockType, payload: Data)] {
        var result: [(MetadataBlock.BlockType, Data)] = []

        // STREAMINFO must be first.
        guard let streamInfoBlock = blocks.first(where: { $0.type == .streamInfo }) else {
            throw FLACError.unsupportedStreamInfo
        }
        result.append((.streamInfo, try streamInfoBlock.loadPayload(from: source)))

        // Collect preserved blocks, partitioning pictures out so we can
        // append them at the tail.
        var smallPreserved: [(MetadataBlock.BlockType, Data)] = []
        var pictures: [(MetadataBlock.BlockType, Data)] = []
        for block in blocks {
            switch block.type {
            case .streamInfo, .padding, .vorbisComment:
                continue
            case .picture:
                pictures.append((.picture, try block.loadPayload(from: source)))
            default:
                smallPreserved.append((block.type, try block.loadPayload(from: source)))
            }
        }

        result.append(contentsOf: smallPreserved)
        result.append((.vorbisComment, tags.encoded()))
        result.append((.padding, Data(count: 4096)))
        result.append(contentsOf: pictures)
        return result
    }

    private func encodeBlockHeader(type: MetadataBlock.BlockType, isLast: Bool, length: Int) -> Data {
        var header = Data(count: 4)
        var h0 = type.rawValue & 0x7F
        if isLast { h0 |= 0x80 }
        header[0] = h0
        header[1] = UInt8((length >> 16) & 0xff)
        header[2] = UInt8((length >> 8) & 0xff)
        header[3] = UInt8(length & 0xff)
        return header
    }
}
