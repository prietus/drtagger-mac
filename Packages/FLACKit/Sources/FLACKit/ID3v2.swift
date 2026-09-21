import Foundation

// Minimal ID3v2 reader and writer.
//
// The goal is round-tripping the small set of frames audiophile tagging
// cares about: title, artist, album, album artist, date, track number,
// disc number, genre, composer, label, catalog number, barcode, media,
// and a couple of free-form TXXX entries. We do NOT touch APIC (cover
// art) frames; the writer preserves any unknown frames it found on the
// way in so picture data and other client-specific tags survive a
// round-trip untouched.
//
// Read: supports ID3v2.3 and v2.4. All four text encodings (ISO-8859-1,
// UTF-16 with BOM, UTF-16BE, UTF-8). Frame size is parsed as syncsafe
// for v2.4 and as plain big-endian for v2.3 (the spec is exactly that
// inconsistency).
//
// Write: emits ID3v2.3 with UTF-16-LE-with-BOM text frames. v2.3 + UTF-16
// is the most broadly compatible combination across audiophile players
// (Foobar2000, JRiver, Audirvana, MPD, Hi-Fi Rose, etc.) and avoids the
// v2.4 unsynchronisation drama. The size field is written as a syncsafe
// integer in the header, plain big-endian in each frame header.

public struct ID3v2Tag: Sendable, Equatable {
    public var frames: [ID3v2Frame]

    public init(frames: [ID3v2Frame] = []) {
        self.frames = frames
    }
}

public struct ID3v2Frame: Sendable, Equatable {
    public let id: String          // 4-char frame ID, e.g. "TIT2", "TXXX", "COMM", "APIC"
    public let flags: UInt16
    public let payload: Data       // raw frame body, encoding byte included for text frames

    public init(id: String, flags: UInt16 = 0, payload: Data) {
        self.id = id
        self.flags = flags
        self.payload = payload
    }
}

public enum ID3v2Error: Error, Equatable {
    case notAnID3Tag
    case unsupportedVersion(major: UInt8, minor: UInt8)
    case truncated
    case invalidFrame(id: String, reason: String)
}

// MARK: - Reading

public extension ID3v2Tag {
    // Parses an ID3v2 header + frame block from `data` starting at offset 0.
    // Returns the parsed tag and the total number of bytes consumed (header
    // + frame data + padding) so callers can locate whatever follows.
    static func parse(_ data: Data) throws -> (tag: ID3v2Tag, totalSize: Int) {
        guard data.count >= 10 else { throw ID3v2Error.truncated }
        guard data[0] == 0x49, data[1] == 0x44, data[2] == 0x33 else {
            throw ID3v2Error.notAnID3Tag
        }
        let major = data[3]
        let minor = data[4]
        guard major == 3 || major == 4 else {
            throw ID3v2Error.unsupportedVersion(major: major, minor: minor)
        }
        let flags = data[5]
        let size = decodeSyncsafe(data[6...9])
        let totalSize = 10 + size
        guard data.count >= totalSize else { throw ID3v2Error.truncated }

        var cursor = 10
        // Skip extended header if present (bit 6 of flags). For our minimal
        // reader we just read its size and jump past — we don't use any of
        // its fields.
        if (flags & 0x40) != 0 {
            guard cursor + 4 <= totalSize else { throw ID3v2Error.truncated }
            let extSize = major == 4
                ? decodeSyncsafe(data[cursor..<(cursor + 4)])
                : Int(beUInt32(data[cursor..<(cursor + 4)]))
            cursor += extSize
        }

        var frames: [ID3v2Frame] = []
        while cursor + 10 <= totalSize {
            // Padding starts when the frame ID is all zeros.
            if data[cursor] == 0 { break }
            let idBytes = data.subdata(in: cursor..<(cursor + 4))
            guard let id = String(data: idBytes, encoding: .ascii), id.count == 4 else {
                throw ID3v2Error.invalidFrame(id: "?", reason: "non-ASCII frame id")
            }
            let frameSize: Int = {
                if major == 4 {
                    return decodeSyncsafe(data[(cursor + 4)..<(cursor + 8)])
                } else {
                    return Int(beUInt32(data[(cursor + 4)..<(cursor + 8)]))
                }
            }()
            let frameFlags = (UInt16(data[cursor + 8]) << 8) | UInt16(data[cursor + 9])
            cursor += 10
            guard cursor + frameSize <= totalSize else { break }
            let payload = data.subdata(in: cursor..<(cursor + frameSize))
            frames.append(ID3v2Frame(id: id, flags: frameFlags, payload: payload))
            cursor += frameSize
        }

        return (ID3v2Tag(frames: frames), totalSize)
    }
}

// MARK: - Writing

public extension ID3v2Tag {
    // Encodes the tag as a v2.3 ID3 block. The output starts with the
    // 10-byte ID3 header and is sized so the total length matches the
    // syncsafe size field. Callers append this to whatever container
    // (DSF metadata pointer, WAV `id3 ` chunk) they need.
    func encodedV23() -> Data {
        var body = Data()
        for frame in frames {
            // Skip ID3 frames whose IDs aren't legal v2.3 (e.g. all-numeric
            // or v2.2 3-char IDs that snuck in from broken sources).
            guard frame.id.count == 4, frame.id.allSatisfy({ $0.isLetter || $0.isNumber }) else {
                continue
            }
            body.append(frame.id.data(using: .ascii) ?? Data(repeating: 0, count: 4))
            // v2.3 size = plain big-endian unsigned 32-bit.
            let size = UInt32(frame.payload.count)
            body.append(UInt8((size >> 24) & 0xff))
            body.append(UInt8((size >> 16) & 0xff))
            body.append(UInt8((size >> 8) & 0xff))
            body.append(UInt8(size & 0xff))
            body.append(UInt8((frame.flags >> 8) & 0xff))
            body.append(UInt8(frame.flags & 0xff))
            body.append(frame.payload)
        }

        var header = Data()
        header.append(contentsOf: [0x49, 0x44, 0x33])    // "ID3"
        header.append(0x03)                              // major
        header.append(0x00)                              // minor
        header.append(0x00)                              // flags (no unsync, no ext header)
        header.append(contentsOf: encodeSyncsafe(body.count))

        var out = Data()
        out.append(header)
        out.append(body)
        return out
    }
}

// MARK: - Vorbis bridging
//
// Vorbis comments are the canonical internal tag format in drtagger,
// because the FLAC pipeline uses them and they're trivially flat. ID3
// frames map onto them through this static table; anything not in the
// table goes through TXXX (custom user-defined frames keyed by their
// description string).

public enum ID3v2Bridge {
    // Standard ID3v2 → Vorbis name mapping. The reverse is generated
    // automatically. Keep these aligned with what TagMerge writes.
    private static let frameToVorbis: [String: String] = [
        "TALB": "ALBUM",
        "TIT2": "TITLE",
        "TPE1": "ARTIST",
        "TPE2": "ALBUMARTIST",
        "TRCK": "TRACKNUMBER",
        "TPOS": "DISCNUMBER",
        "TYER": "DATE",     // v2.3 year-only
        "TDRC": "DATE",     // v2.4 full date
        "TCON": "GENRE",
        "TCOM": "COMPOSER",
        "TPUB": "LABEL",
        "TMED": "MEDIA",
        "TSRC": "ISRC",
    ]

    // Reverse table built once.
    private static let vorbisToFrame: [String: String] = {
        var out: [String: String] = [:]
        for (frame, vorbis) in frameToVorbis {
            // Prefer TDRC (v2.4) over TYER for DATE on the way back? We
            // emit v2.3 so always pick TYER for "DATE".
            if vorbis == "DATE" && frame != "TYER" { continue }
            out[vorbis] = frame
        }
        return out
    }()

    // Names that should always go through TXXX even though they look
    // like they could fit a standard frame. CATALOGNUMBER and BARCODE
    // are the audiophile staples and intentionally TXXX.
    private static let alwaysTXXX: Set<String> = [
        "CATALOGNUMBER",
        "BARCODE",
        "RELEASECOUNTRY",
        "STYLE",
        "PERFORMER",
        "PRODUCER",
        "LABEL",  // many tagger tools store LABEL via TXXX too; we keep TPUB primary
    ]

    // Convert an ID3v2 tag block into a VorbisComment. Multi-value
    // frames (separated by NULL in the payload, or repeated frames)
    // become repeated Vorbis fields with the same name.
    public static func toVorbis(_ tag: ID3v2Tag, vendor: String = "drtagger-id3") -> VorbisComment {
        var fields: [(name: String, value: String)] = []
        for frame in tag.frames {
            // Picture frames preserved opaquely below — bridging skips them.
            if frame.id == "APIC" { continue }

            if frame.id == "TXXX" {
                if let pair = decodeTXXX(frame.payload) {
                    fields.append((name: pair.description.uppercased(), value: pair.value))
                }
                continue
            }
            if frame.id == "COMM" {
                if let comment = decodeCOMM(frame.payload) {
                    fields.append((name: "COMMENT", value: comment))
                }
                continue
            }
            if frame.id.hasPrefix("T"),
               let vorbisName = frameToVorbis[frame.id] {
                for value in decodeTextFrame(frame.payload) where !value.isEmpty {
                    fields.append((name: vorbisName, value: value))
                }
            }
        }
        return VorbisComment(vendor: vendor, fields: fields)
    }

    // Build a v2.3 ID3 tag from a VorbisComment. Unknown Vorbis names
    // become TXXX frames keyed by the name. Multi-value Vorbis fields
    // become one ID3 frame per value (works for TPE1, TCON, TCOM, etc.)
    // — broadly compatible across players.
    //
    // `preservedFrames` lets the caller pass in any non-text frames from
    // the original tag (APIC pictures, PRIV, MCDI…) that should survive
    // the rewrite untouched. We sort them after the new text frames so
    // tag editors that read sequentially still see the metadata first.
    public static func toID3v23(
        _ comment: VorbisComment,
        preserving preservedFrames: [ID3v2Frame] = []
    ) -> ID3v2Tag {
        var frames: [ID3v2Frame] = []
        for (name, value) in comment.fields where !value.isEmpty {
            let upper = name.uppercased()
            if alwaysTXXX.contains(upper) {
                frames.append(makeTXXXFrame(description: upper, value: value))
                continue
            }
            if let frameID = vorbisToFrame[upper] {
                frames.append(makeTextFrame(id: frameID, value: value))
                continue
            }
            // Unknown name → TXXX with the name as the description.
            frames.append(makeTXXXFrame(description: upper, value: value))
        }
        // Append preserved opaque frames (pictures etc.) untouched.
        frames.append(contentsOf: preservedFrames.filter { $0.id == "APIC" || $0.id == "MCDI" || $0.id == "PRIV" || $0.id == "GEOB" })
        return ID3v2Tag(frames: frames)
    }

    // MARK: Frame body codecs

    // Decode a TXXX payload into (description, value).
    // Layout: encoding(1) + description(textZ) + value(text)
    public static func decodeTXXX(_ payload: Data) -> (description: String, value: String)? {
        guard let encoding = payload.first else { return nil }
        let body = payload.dropFirst()
        let split = splitNullTerminated(body, encoding: encoding)
        guard split.count >= 2 else { return nil }
        return (description: split[0], value: split[1])
    }

    // Decode a COMM frame: encoding(1) + lang(3) + descZ + text
    public static func decodeCOMM(_ payload: Data) -> String? {
        guard payload.count >= 4 else { return nil }
        let encoding = payload[payload.startIndex]
        let body = payload.dropFirst(4) // skip encoding + 3-byte language
        let parts = splitNullTerminated(body, encoding: encoding)
        return parts.last
    }

    // Decode a generic text frame: encoding(1) + text(... maybe null-separated)
    public static func decodeTextFrame(_ payload: Data) -> [String] {
        guard let encoding = payload.first else { return [] }
        let body = payload.dropFirst()
        let raw = decodeText(Data(body), encoding: encoding)
        // v2.4 uses NULL as multi-value separator. v2.3 doesn't, but
        // some taggers do it anyway, so we always split.
        return raw
            .split(separator: "\0", omittingEmptySubsequences: true)
            .map(String.init)
    }

    public static func decodeText(_ data: Data, encoding: UInt8) -> String {
        switch encoding {
        case 0:
            return String(data: data, encoding: .isoLatin1) ?? ""
        case 1:
            // UTF-16 with BOM
            return String(data: data, encoding: .utf16) ?? ""
        case 2:
            return String(data: data, encoding: .utf16BigEndian) ?? ""
        case 3:
            return String(data: data, encoding: .utf8) ?? ""
        default:
            return ""
        }
    }

    // Splits a payload (after the encoding byte was already consumed)
    // into pieces separated by the encoding's NULL terminator.
    public static func splitNullTerminated(_ data: Data, encoding: UInt8) -> [String] {
        if encoding == 1 || encoding == 2 {
            // UTF-16: NULL is two zero bytes; alignment matters.
            var pieces: [Data] = []
            var current = Data()
            var i = data.startIndex
            while i < data.endIndex - 1 {
                if data[i] == 0 && data[i + 1] == 0 {
                    pieces.append(current)
                    current = Data()
                    i += 2
                } else {
                    current.append(data[i])
                    current.append(data[i + 1])
                    i += 2
                }
            }
            if i == data.endIndex - 1 {
                current.append(data[i])
            }
            if !current.isEmpty { pieces.append(current) }
            return pieces.map { decodeText($0, encoding: encoding) }
        } else {
            // UTF-8 / ISO-8859-1: NULL is one zero byte.
            var pieces: [Data] = []
            var current = Data()
            for byte in data {
                if byte == 0 {
                    pieces.append(current)
                    current = Data()
                } else {
                    current.append(byte)
                }
            }
            if !current.isEmpty { pieces.append(current) }
            return pieces.map { decodeText($0, encoding: encoding) }
        }
    }

    // MARK: Frame body builders (v2.3 / UTF-16-LE-with-BOM)

    public static func makeTextFrame(id: String, value: String) -> ID3v2Frame {
        var payload = Data([0x01]) // encoding 1 = UTF-16 with BOM
        payload.append(encodeUTF16WithBOM(value))
        return ID3v2Frame(id: id, payload: payload)
    }

    public static func makeTXXXFrame(description: String, value: String) -> ID3v2Frame {
        var payload = Data([0x01])
        payload.append(encodeUTF16WithBOM(description))
        payload.append(contentsOf: [0x00, 0x00]) // UTF-16 NULL
        payload.append(encodeUTF16WithBOM(value))
        return ID3v2Frame(id: "TXXX", payload: payload)
    }

    public static func encodeUTF16WithBOM(_ s: String) -> Data {
        var out = Data([0xFF, 0xFE]) // UTF-16-LE BOM
        for unit in s.utf16 {
            out.append(UInt8(unit & 0xff))
            out.append(UInt8((unit >> 8) & 0xff))
        }
        return out
    }
}

// MARK: - Helpers

private func decodeSyncsafe(_ slice: Data.SubSequence) -> Int {
    let bytes = Array(slice)
    guard bytes.count == 4 else { return 0 }
    return (Int(bytes[0]) << 21) | (Int(bytes[1]) << 14) | (Int(bytes[2]) << 7) | Int(bytes[3])
}

private func encodeSyncsafe(_ value: Int) -> [UInt8] {
    let v = max(0, value)
    return [
        UInt8((v >> 21) & 0x7f),
        UInt8((v >> 14) & 0x7f),
        UInt8((v >> 7) & 0x7f),
        UInt8(v & 0x7f),
    ]
}

private func beUInt32(_ slice: Data.SubSequence) -> UInt32 {
    let bytes = Array(slice)
    guard bytes.count == 4 else { return 0 }
    return (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
}
