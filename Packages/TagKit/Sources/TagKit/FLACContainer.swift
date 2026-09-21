import CryptoKit
import FLACKit
import Foundation

// FLAC: VORBIS_COMMENT + PICTURE blocks. Layout on write follows FLACKit's
// convention (STREAMINFO, small blocks, VORBIS_COMMENT, PADDING, PICTUREs).
enum FLACContainer {

    static let vendor = "drtagger for Mac"

    static func read(url: URL) throws -> ContainerContents {
        let source = try FileHandleDataSource(url: url)
        let file = try FLACFile(source: source)
        var tags = TagSet()
        for (name, value) in file.vorbisComment?.fields ?? [] { tags.add(name, value) }
        var pictures: [Picture] = []
        for block in file.blocks where block.type == .picture {
            if let p = parsePictureBlock(try block.loadPayload(from: source)) { pictures.append(p) }
        }
        let raw = try source.read(at: 4, length: Int(file.audioFrameOffset - 4))
        let digest = try AudioCopier.digest(of: source, offset: file.audioFrameOffset, length: file.audioFrameLength)
        return ContainerContents(tags: tags, pictures: pictures, rawMetadata: raw, audioDigest: digest)
    }

    static func write(url: URL, tags: TagSet, pictures: [Picture]?, to out: FileHandle) throws -> String {
        let source = try FileHandleDataSource(url: url)
        let file = try FLACFile(source: source)
        var blocks: [(MetadataBlock.BlockType, Data)] = []
        guard let streamInfo = file.blocks.first(where: { $0.type == .streamInfo }) else { throw TagFileError.malformed("no STREAMINFO") }
        blocks.append((.streamInfo, try streamInfo.loadPayload(from: source)))
        var pictureBlocks: [Data] = []
        for block in file.blocks {
            switch block.type {
            case .streamInfo, .padding, .vorbisComment: continue
            case .picture: if pictures == nil { pictureBlocks.append(try block.loadPayload(from: source)) }
            default: blocks.append((block.type, try block.loadPayload(from: source)))
            }
        }
        if let pictures { pictureBlocks = pictures.map(pictureBlock) }
        let comment = VorbisComment(vendor: file.vorbisComment?.vendor ?? vendor, fields: tags.pairs.map { (name: $0.name, value: $0.value) })
        blocks.append((.vorbisComment, comment.encoded()))
        blocks.append((.padding, Data(count: 4096)))
        blocks.append(contentsOf: pictureBlocks.map { (.picture, $0) })

        try out.write(contentsOf: Data([0x66, 0x4C, 0x61, 0x43]))
        for (i, (type, payload)) in blocks.enumerated() {
            try out.write(contentsOf: header(type: type, isLast: i == blocks.count - 1, length: payload.count))
            try out.write(contentsOf: payload)
        }
        var hasher = SHA256()
        try AudioCopier.copy(from: source, offset: file.audioFrameOffset, length: file.audioFrameLength, to: out, hasher: &hasher)
        return hasher.hex
    }

    static func restore(url: URL, rawMetadata: Data, to out: FileHandle) throws -> String {
        let source = try FileHandleDataSource(url: url)
        let file = try FLACFile(source: source)
        try out.write(contentsOf: Data([0x66, 0x4C, 0x61, 0x43]))
        try out.write(contentsOf: rawMetadata)
        var hasher = SHA256()
        try AudioCopier.copy(from: source, offset: file.audioFrameOffset, length: file.audioFrameLength, to: out, hasher: &hasher)
        return hasher.hex
    }

    static func header(type: MetadataBlock.BlockType, isLast: Bool, length: Int) -> Data {
        Data([type.rawValue | (isLast ? 0x80 : 0), UInt8((length >> 16) & 0xff), UInt8((length >> 8) & 0xff), UInt8(length & 0xff)])
    }

    // PICTURE block: type, mime, description, width, height, depth, colors, data (all big-endian, length-prefixed).
    static func pictureBlock(_ p: Picture) -> Data {
        var d = Data()
        d.appendU32BE(UInt32(p.kind.rawValue))
        let mime = Data(p.mimeType.utf8); d.appendU32BE(UInt32(mime.count)); d.append(mime)
        let desc = Data(p.description.utf8); d.appendU32BE(UInt32(desc.count)); d.append(desc)
        d.appendU32BE(UInt32(p.width)); d.appendU32BE(UInt32(p.height)); d.appendU32BE(24); d.appendU32BE(0)
        d.appendU32BE(UInt32(p.data.count)); d.append(p.data)
        return d
    }

    static func parsePictureBlock(_ d: Data) -> Picture? {
        guard d.count >= 32 else { return nil }
        var c = 0
        let kind = Picture.Kind(rawValue: Int(d.u32BE(c))) ?? .other; c += 4
        let mimeLen = Int(d.u32BE(c)); c += 4
        guard d.count >= c + mimeLen + 4 else { return nil }
        let mime = d.ascii(c, mimeLen); c += mimeLen
        let descLen = Int(d.u32BE(c)); c += 4
        guard d.count >= c + descLen + 20 else { return nil }
        let desc = String(decoding: d[(d.startIndex + c)..<(d.startIndex + c + descLen)], as: UTF8.self); c += descLen
        let width = Int(d.u32BE(c)), height = Int(d.u32BE(c + 4)); c += 16
        let len = Int(d.u32BE(c)); c += 4
        guard d.count >= c + len else { return nil }
        return Picture(kind: kind, mimeType: mime, data: d.subdata(in: (d.startIndex + c)..<(d.startIndex + c + len)), width: width, height: height, description: desc)
    }
}
