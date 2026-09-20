import Foundation

// Threshold above which metadata blocks are kept as offset/length references
// rather than loaded into memory. Anything large (PICTURE, oversized SEEKTABLE,
// APPLICATION) stays on disk until explicitly requested.
private let inlinePayloadLimit: Int = 64 * 1024

public struct FLACFile: Sendable {
    public let streamInfo: StreamInfo
    public var vorbisComment: VorbisComment?
    public let blocks: [MetadataBlock]
    public let audioFrameOffset: UInt64
    public let audioFrameLength: UInt64

    init(
        streamInfo: StreamInfo,
        vorbisComment: VorbisComment?,
        blocks: [MetadataBlock],
        audioFrameOffset: UInt64,
        audioFrameLength: UInt64
    ) {
        self.streamInfo = streamInfo
        self.vorbisComment = vorbisComment
        self.blocks = blocks
        self.audioFrameOffset = audioFrameOffset
        self.audioFrameLength = audioFrameLength
    }

    // Convenience for the common local case. For NAS reads via WebDAV, the
    // app layer constructs a FLACFile from a HTTP-range-backed DataSource
    // instead — the parser itself doesn't care about the transport.
    public init(url: URL) throws {
        let source = try FileHandleDataSource(url: url)
        try self.init(source: source)
    }

    public init(data: Data) throws {
        try self.init(source: DataDataSource(data))
    }

    // When `totalLength` is non-nil the parser uses it as the authoritative
    // file size (audioFrameLength = totalLength - audioFrameOffset), and the
    // `source` is allowed to cover only a prefix of the real file. This is
    // how the WebDAV "read 64KB, parse tags" fast path works: the source is
    // a DataDataSource wrapping a Range response, but the real file on the
    // server is much larger. Reference blocks that extend beyond the prefix
    // are stored as (offset, length) without being read — attempting to
    // loadPayload on them later with the prefix source will correctly fail
    // with `.truncated`, but tag-only callers never do that.
    public init(source: any FLACDataSource, totalLength: UInt64? = nil) throws {
        let sourceLength = try source.length
        let total = totalLength ?? sourceLength
        guard sourceLength >= 4 else { throw FLACError.truncated }

        let magic = try source.read(at: 0, length: 4)
        guard magic[0] == 0x66, magic[1] == 0x4C, magic[2] == 0x61, magic[3] == 0x43 else {
            throw FLACError.notAFLACFile
        }

        var cursor: UInt64 = 4
        var blocks: [MetadataBlock] = []
        var streamInfo: StreamInfo?
        var vorbis: VorbisComment?
        var isLast = false

        while !isLast {
            // If the next block header is already past the end of the
            // source buffer, we're parsing a prefix that ran out mid-way
            // through a referenced block (typically PICTURE). That's not
            // an error for tag-only callers — we stop here, keep whatever
            // we've parsed, and let the caller decide whether to fetch
            // more bytes. Any caller that actually needs to traverse the
            // missing blocks will call loadPayload with a full source.
            if cursor + 4 > sourceLength {
                if totalLength != nil { break }
                throw FLACError.truncated
            }
            let header = try source.read(at: cursor, length: 4)
            cursor += 4
            isLast = (header[0] & 0x80) != 0
            let typeRaw = header[0] & 0x7F
            let length = (Int(header[1]) << 16) | (Int(header[2]) << 8) | Int(header[3])

            let type = MetadataBlock.BlockType(rawValue: typeRaw) ?? .invalid
            let mustLoad = (type == .streamInfo || type == .vorbisComment)
            let willInline = mustLoad || length <= inlinePayloadLimit

            let payload: MetadataBlock.Payload
            if willInline {
                // For blocks we inline we need the bytes now; bail if the
                // source is too short (truncated real file, or prefix buffer
                // smaller than the metadata section).
                guard cursor + UInt64(length) <= sourceLength else {
                    throw FLACError.truncated
                }
                let data = try source.read(at: cursor, length: length)
                payload = .inline(data)
                if type == .streamInfo {
                    streamInfo = try StreamInfo.parse(data)
                } else if type == .vorbisComment {
                    vorbis = try VorbisComment.parse(data)
                }
            } else {
                // Reference blocks are cheap — we only record offset+length
                // and never touch the bytes here. This is what lets a 64KB
                // prefetch parse a file with a 150KB PICTURE block.
                payload = .reference(offset: cursor, length: length)
            }

            blocks.append(MetadataBlock(type: type, isLast: isLast, payload: payload))
            cursor += UInt64(length)
        }

        guard let streamInfo else { throw FLACError.unsupportedStreamInfo }
        // audioFrameLength uses the caller-provided total. For prefix-buffer
        // parses this is the real file size; for whole-file parses it's just
        // source.length, which we default to via `total`.
        let audioLength = cursor < total ? total - cursor : 0
        self.init(
            streamInfo: streamInfo,
            vorbisComment: vorbis,
            blocks: blocks,
            audioFrameOffset: cursor,
            audioFrameLength: audioLength
        )
    }
}
