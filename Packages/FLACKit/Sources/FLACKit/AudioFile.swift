import Foundation

// Format-agnostic wrapper around the file types FLACKit can parse and
// rewrite. LibraryModel uses this so it can iterate over a folder full
// of mixed FLAC / DSF / WAV without branching on the file extension at
// every call site.
//
// Internally each case carries the format-specific parsed object so the
// rewrite path can stream audio frames straight from the source without
// duplicating any of the per-format byte layout knowledge.

public enum AudioFile: Sendable {
    case flac(FLACFile)
    case dsf(DSFFile)
    case wav(WAVFile)

    public enum Format: String, Sendable {
        case flac, dsf, wav
    }

    public var format: Format {
        switch self {
        case .flac: return .flac
        case .dsf:  return .dsf
        case .wav:  return .wav
        }
    }

    public var sampleRate: Int? {
        switch self {
        case .flac(let f): return Int(f.streamInfo.sampleRate)
        case .dsf(let d):  return d.sampleRate
        case .wav(let w):  return w.sampleRate
        }
    }

    public var bitsPerSample: Int? {
        switch self {
        case .flac(let f): return Int(f.streamInfo.bitsPerSample)
        case .dsf(let d):  return d.bitsPerSample
        case .wav(let w):  return w.bitsPerSample
        }
    }

    // Best-effort audio duration. FLAC carries totalSamples in its
    // streamInfo block so we can return it cheaply; WAV and DSF would
    // need extra parsing we don't do at load time, so they return nil.
    // Used by the fingerprint fallback to prefer the longest track in
    // an album (more distinctive audio surface → better AcoustID hit
    // rate than a short intro or interlude).
    public var durationSeconds: Double? {
        switch self {
        case .flac(let f):
            let d = f.streamInfo.durationSeconds
            return d > 0 ? d : nil
        case .dsf(let d):
            guard d.sampleRate > 0 else { return nil }
            let dur = Double(d.sampleCount) / Double(d.sampleRate)
            return dur > 0 ? dur : nil
        case .wav:
            return nil
        }
    }

    // Returns the file's tags translated into the canonical Vorbis-style
    // (name, value) shape regardless of the on-disk format. ID3v2 frames
    // are bridged through ID3v2Bridge so callers see the same field
    // names FLAC files use ("ALBUM", "TITLE", "ARTIST", …).
    public var vorbisComment: VorbisComment? {
        switch self {
        case .flac(let f):
            return f.vorbisComment
        case .dsf(let d):
            guard let tag = d.id3Tag else { return nil }
            return ID3v2Bridge.toVorbis(tag)
        case .wav(let w):
            guard let tag = w.id3Tag else { return nil }
            return ID3v2Bridge.toVorbis(tag)
        }
    }

    // Sniffs the first four bytes of the source and returns the right
    // parser. The 4-byte limit is enough to disambiguate every format
    // we currently support without speculative reads.
    public static func open(source: any FLACDataSource, totalLength: UInt64? = nil) throws -> AudioFile {
        let length = try source.length
        guard length >= 4 else { throw FLACError.truncated }
        let magic = try source.read(at: 0, length: 4)
        // FLAC: "fLaC"
        if magic[0] == 0x66, magic[1] == 0x4C, magic[2] == 0x61, magic[3] == 0x43 {
            return .flac(try FLACFile(source: source, totalLength: totalLength))
        }
        // DSF: "DSD "
        if magic[0] == 0x44, magic[1] == 0x53, magic[2] == 0x44, magic[3] == 0x20 {
            return .dsf(try DSFFile(source: source, totalLength: totalLength))
        }
        // WAV: "RIFF"
        if magic[0] == 0x52, magic[1] == 0x49, magic[2] == 0x46, magic[3] == 0x46 {
            return .wav(try WAVFile(source: source, totalLength: totalLength))
        }
        throw FLACError.notAFLACFile
    }

    // Rewrites the file with new tags. The audio payload is streamed
    // from the source so the resulting bytes are byte-identical for
    // everything outside the metadata section — same MD5 if you compute
    // it against the audio chunks.
    public func rewritten(with vorbis: VorbisComment, source: any FLACDataSource) throws -> Data {
        switch self {
        case .flac(let f): return try f.rewritten(with: vorbis, source: source)
        case .dsf(let d):  return try d.rewritten(with: vorbis, source: source)
        case .wav(let w):  return try w.rewritten(with: vorbis, source: source)
        }
    }

    // File extensions LibraryModel cares about. Centralised here so
    // adding a new format only takes a tweak in one place.
    public static let supportedExtensions: [String] = ["flac", "dsf", "wav"]

    public static func isSupported(filename: String) -> Bool {
        let lower = filename.lowercased()
        return supportedExtensions.contains { lower.hasSuffix(".\($0)") }
    }
}
