import CryptoKit
import FLACKit
import Foundation

// RIFF/WAVE, FORM/AIFF and FRM8/DSDIFF share one shape: a header, then
// chunks; the tag lives in an "id3 " / "ID3 " chunk. Only the size width
// and byte order differ.
struct IFFContainer {
    enum Flavor { case wav, aiff, dff }

    let flavor: Flavor
    var sizeWidth: Int { flavor == .dff ? 8 : 4 }
    var littleEndian: Bool { flavor == .wav }
    var headerLength: Int { 4 + sizeWidth + 4 }     // magic + size + form type
    var audioChunkID: String { switch flavor { case .wav: return "data"; case .aiff: return "SSND"; case .dff: return "DSD " } }
    var tagChunkID: String { flavor == .wav ? "id3 " : "ID3 " }

    struct Chunk { let id: String; let offset: UInt64; let size: UInt64; let headerSize: Int
        var payloadOffset: UInt64 { offset + UInt64(headerSize) }
        var padded: UInt64 { size + (size % 2) }
        var isTag: Bool { id == "id3 " || id == "ID3 " }
    }

    func chunks(_ source: any FLACDataSource) throws -> [Chunk] {
        let total = try source.length
        guard total >= UInt64(headerLength) else { throw TagFileError.malformed("file too short") }
        let head = try source.read(at: 0, length: headerLength)
        let magic = head.ascii(0, 4)
        let expected = flavor == .wav ? "RIFF" : flavor == .aiff ? "FORM" : "FRM8"
        guard magic == expected else { throw TagFileError.malformed("expected \(expected), found \(magic)") }
        var list: [Chunk] = []
        var cursor = UInt64(headerLength)
        while cursor + UInt64(4 + sizeWidth) <= total {
            let h = try source.read(at: cursor, length: 4 + sizeWidth)
            let id = h.ascii(0, 4)
            let size: UInt64 = sizeWidth == 8 ? h.u64BE(4) : (littleEndian ? UInt64(h.u32LE(4)) : UInt64(h.u32BE(4)))
            list.append(Chunk(id: id, offset: cursor, size: size, headerSize: 4 + sizeWidth))
            let next = cursor + UInt64(4 + sizeWidth) + size + (size % 2)
            if next <= cursor { break }
            cursor = next
        }
        return list
    }

    func read(url: URL) throws -> ContainerContents {
        let source = try FileHandleDataSource(url: url)
        let list = try chunks(source)
        var parsed = ID3Mapper.Parsed(tags: TagSet(), pictures: [], preserved: [])
        var raw = Data()
        if let tag = list.first(where: \.isTag), tag.size > 10 {
            raw = try source.read(at: tag.payloadOffset, length: Int(tag.size))
            if let (t, _) = try? ID3v2Tag.parse(raw) { parsed = ID3Mapper.parse(t) }
        }
        let digest = try audioDigest(source, list)
        return ContainerContents(tags: parsed.tags, pictures: parsed.pictures, rawMetadata: raw, audioDigest: digest, preserved: parsed.preserved)
    }

    private func audioDigest(_ source: any FLACDataSource, _ list: [Chunk]) throws -> String {
        var hasher = SHA256()
        for c in list where c.id == audioChunkID {
            try AudioCopier.copy(from: source, offset: c.payloadOffset, length: c.size, to: nil, hasher: &hasher)
        }
        return hasher.hex
    }

    func write(url: URL, tags: TagSet, pictures: [Picture]?, to out: FileHandle) throws -> String {
        let contents = try read(url: url)
        let tag = ID3Mapper.tag(from: tags, pictures: pictures ?? contents.pictures, preserved: contents.preserved)
        return try emit(url: url, tagBytes: tag.encodedV23(), to: out)
    }

    func restore(url: URL, rawMetadata: Data, to out: FileHandle) throws -> String {
        try emit(url: url, tagBytes: rawMetadata, to: out)
    }

    private func emit(url: URL, tagBytes: Data, to out: FileHandle) throws -> String {
        let source = try FileHandleDataSource(url: url)
        let list = try chunks(source)
        var head = try source.read(at: 0, length: headerLength)
        head.replaceSubrange(4..<(4 + sizeWidth), with: Data(count: sizeWidth))   // patched below
        try out.write(contentsOf: head)
        var hasher = SHA256()
        for c in list where !c.isTag {
            try out.write(contentsOf: try source.read(at: c.offset, length: c.headerSize))
            if c.id == audioChunkID {
                try AudioCopier.copy(from: source, offset: c.payloadOffset, length: c.size, to: out, hasher: &hasher)
                if c.size % 2 == 1 { try out.write(contentsOf: Data([0])) }
            } else {
                var scratch = SHA256()
                try AudioCopier.copy(from: source, offset: c.payloadOffset, length: c.padded, to: out, hasher: &scratch)
            }
        }
        if !tagBytes.isEmpty {
            var h = Data(tagChunkID.utf8)
            if sizeWidth == 8 { h.appendU64BE(UInt64(tagBytes.count)) } else if littleEndian { h.appendU32LE(UInt32(tagBytes.count)) } else { h.appendU32BE(UInt32(tagBytes.count)) }
            try out.write(contentsOf: h)
            try out.write(contentsOf: tagBytes)
            if tagBytes.count % 2 == 1 { try out.write(contentsOf: Data([0])) }
        }
        // Top-level size = everything after magic + size field.
        let total = try out.offset()
        var sizeField = Data()
        let value = total - UInt64(4 + sizeWidth)
        if sizeWidth == 8 { sizeField.appendU64BE(value) } else if littleEndian { sizeField.appendU32LE(UInt32(value)) } else { sizeField.appendU32BE(UInt32(value)) }
        try out.seek(toOffset: 4)
        try out.write(contentsOf: sizeField)
        try out.seek(toOffset: total)
        return hasher.hex
    }
}
