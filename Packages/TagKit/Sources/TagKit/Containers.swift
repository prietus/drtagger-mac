import CryptoKit
import FLACKit
import Foundation

public enum TagContainer: String, Sendable, Codable, Hashable {
    case flac, dsf, wav, aiff, dff, ape, mp4

    public static func from(url: URL) -> TagContainer? {
        switch url.pathExtension.lowercased() {
        case "flac": return .flac
        case "dsf": return .dsf
        case "wav", "wave": return .wav
        case "aiff", "aif", "aifc": return .aiff
        case "dff": return .dff
        case "ape", "wv", "tta": return .ape
        case "m4a", "mp4", "m4b": return .mp4
        default: return nil
        }
    }
}

public enum TagFileError: Error, LocalizedError, Equatable {
    case unsupportedContainer(String)
    case malformed(String)
    case audioChanged(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedContainer(let ext): return "Unsupported file type: .\(ext)"
        case .malformed(let why): return "File structure not understood: \(why)"
        case .audioChanged(let e, let a): return "Audio bytes changed during write (\(e.prefix(8)) → \(a.prefix(8))); original restored."
        }
    }
}

// What a container hands back: the tags, the pictures, the raw metadata
// bytes (for backups) and a digest of the audio payload.
public struct ContainerContents: Sendable {
    public var tags: TagSet
    public var pictures: [Picture]
    public var rawMetadata: Data           // enough to restore the original tags byte-exact
    public var audioDigest: String         // SHA-256 of the audio payload, hex
    public var preserved: [ID3v2Frame]     // ID3 containers only
    public var opaque: Data                // container-specific leftovers (APE binary items, MP4 unknown ilst atoms)

    public init(tags: TagSet, pictures: [Picture], rawMetadata: Data, audioDigest: String, preserved: [ID3v2Frame] = [], opaque: Data = Data()) {
        self.tags = tags; self.pictures = pictures; self.rawMetadata = rawMetadata; self.audioDigest = audioDigest
        self.preserved = preserved; self.opaque = opaque
    }
}

// Streams `length` bytes from `offset` of `source` into `out`, hashing on the way.
struct AudioCopier {
    static let chunk = 1 << 20

    static func copy(from source: any FLACDataSource, offset: UInt64, length: UInt64, to out: FileHandle?, hasher: inout SHA256) throws {
        var remaining = length
        var cursor = offset
        while remaining > 0 {
            let take = Int(min(UInt64(chunk), remaining))
            let data = try source.read(at: cursor, length: take)
            hasher.update(data: data)
            try out?.write(contentsOf: data)
            cursor += UInt64(take)
            remaining -= UInt64(take)
        }
    }

    static func digest(of source: any FLACDataSource, offset: UInt64, length: UInt64) throws -> String {
        var h = SHA256()
        try copy(from: source, offset: offset, length: length, to: nil, hasher: &h)
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension SHA256 {
    var hex: String { finalize().map { String(format: "%02x", $0) }.joined() }
}

// MARK: - Little helpers

extension Data {
    func u32LE(_ at: Int) -> UInt32 { withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt32.self).littleEndian } }
    func u32BE(_ at: Int) -> UInt32 { withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt32.self).bigEndian } }
    func u64LE(_ at: Int) -> UInt64 { withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt64.self).littleEndian } }
    func u64BE(_ at: Int) -> UInt64 { withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt64.self).bigEndian } }
    func u16BE(_ at: Int) -> UInt16 { withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt16.self).bigEndian } }
    func ascii(_ at: Int, _ n: Int) -> String { String(decoding: self[(startIndex + at)..<(startIndex + at + n)], as: UTF8.self) }

    mutating func appendU32LE(_ v: UInt32) { var x = v.littleEndian; Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) } }
    mutating func appendU32BE(_ v: UInt32) { var x = v.bigEndian; Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) } }
    mutating func appendU64LE(_ v: UInt64) { var x = v.littleEndian; Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) } }
    mutating func appendU64BE(_ v: UInt64) { var x = v.bigEndian; Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) } }
    mutating func appendU16BE(_ v: UInt16) { var x = v.bigEndian; Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) } }
}
