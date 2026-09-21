import CryptoKit
import FLACKit
import Foundation

// DSF: ID3v2 trailer referenced from the DSD chunk's metadata pointer.
enum DSFContainer {

    static func read(url: URL) throws -> ContainerContents {
        let source = try FileHandleDataSource(url: url)
        let file = try DSFFile(source: source)
        let parsed = file.id3Tag.map(ID3Mapper.parse) ?? ID3Mapper.Parsed(tags: TagSet(), pictures: [], preserved: [])
        var raw = Data()
        let total = try source.length
        if file.id3Offset > 0, file.id3Offset < total {
            raw = try source.read(at: file.id3Offset, length: Int(total - file.id3Offset))
        }
        let digest = try AudioCopier.digest(of: source, offset: file.dataChunkOffset + 12, length: file.audioByteCount)
        return ContainerContents(tags: parsed.tags, pictures: parsed.pictures, rawMetadata: raw, audioDigest: digest, preserved: parsed.preserved)
    }

    static func write(url: URL, tags: TagSet, pictures: [Picture]?, to out: FileHandle) throws -> String {
        let contents = try read(url: url)
        let tag = ID3Mapper.tag(from: tags, pictures: pictures ?? contents.pictures, preserved: contents.preserved)
        return try emit(url: url, tagBytes: tag.encodedV23(), to: out)
    }

    static func restore(url: URL, rawMetadata: Data, to out: FileHandle) throws -> String {
        try emit(url: url, tagBytes: rawMetadata, to: out)
    }

    private static func emit(url: URL, tagBytes: Data, to out: FileHandle) throws -> String {
        let source = try FileHandleDataSource(url: url)
        let file = try DSFFile(source: source)
        let audioStart = file.dataChunkOffset + 12
        let pointer = audioStart + file.audioByteCount
        let total = pointer + UInt64(tagBytes.count)
        var head = Data([0x44, 0x53, 0x44, 0x20])
        head.appendU64LE(28); head.appendU64LE(total); head.appendU64LE(tagBytes.isEmpty ? 0 : pointer)
        try out.write(contentsOf: head)
        try out.write(contentsOf: try source.read(at: file.fmtChunkOffset, length: 52))
        try out.write(contentsOf: try source.read(at: file.dataChunkOffset, length: 12))
        var hasher = SHA256()
        try AudioCopier.copy(from: source, offset: audioStart, length: file.audioByteCount, to: out, hasher: &hasher)
        try out.write(contentsOf: tagBytes)
        return hasher.hex
    }
}
