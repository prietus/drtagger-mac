import Foundation

// FLAC metadata block layout (spec: https://xiph.org/flac/format.html#metadata_block)
// Header is 4 bytes:
//   bit 0       : last-metadata-block flag
//   bits 1..7   : block type (0..126, 127 = invalid)
//   bits 8..31  : block length in bytes (big-endian, excludes the 4-byte header)
//
// The parser keeps small blocks inline (so STREAMINFO, VORBIS_COMMENT, SEEKTABLE,
// PADDING etc. are immediately available) and records large blocks — PICTURE in
// particular — as offset/length references. That keeps a tag-only open of a
// 500MB FLAC over SMB under ~16KB of actual bytes read, while still letting us
// fetch the big block on demand when we have to rewrite the file.

public struct MetadataBlock: Equatable, Sendable {
    public enum BlockType: UInt8, Sendable {
        case streamInfo    = 0
        case padding       = 1
        case application   = 2
        case seekTable     = 3
        case vorbisComment = 4
        case cueSheet      = 5
        case picture       = 6
        case invalid       = 127
    }

    public enum Payload: Equatable, Sendable {
        case inline(Data)
        case reference(offset: UInt64, length: Int)

        public var length: Int {
            switch self {
            case .inline(let d): return d.count
            case .reference(_, let n): return n
            }
        }
    }

    public let type: BlockType
    public let isLast: Bool
    public let payload: Payload

    public init(type: BlockType, isLast: Bool, payload: Payload) {
        self.type = type
        self.isLast = isLast
        self.payload = payload
    }

    // Resolves the payload to concrete bytes, reading from the source only
    // if the block was stored as a reference.
    public func loadPayload(from source: any FLACDataSource) throws -> Data {
        switch payload {
        case .inline(let d): return d
        case .reference(let offset, let length):
            return try source.read(at: offset, length: length)
        }
    }
}
