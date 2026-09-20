import Foundation

// Vorbis comment layout (little-endian, unlike the rest of FLAC):
//   u32  vendor_length
//   u8[] vendor_string (UTF-8)
//   u32  comment_list_length
//   for each comment:
//     u32  length
//     u8[] "NAME=value" (UTF-8)
//
// Field names are case-insensitive ASCII (0x20..0x7D excluding '='); values are UTF-8.
// Duplicate names are legal and meaningful (e.g. multiple ARTIST entries).

public struct VorbisComment: Equatable, Sendable {
    public var vendor: String
    public var fields: [(name: String, value: String)]

    public init(vendor: String, fields: [(name: String, value: String)]) {
        self.vendor = vendor
        self.fields = fields
    }

    public static func == (lhs: VorbisComment, rhs: VorbisComment) -> Bool {
        guard lhs.vendor == rhs.vendor, lhs.fields.count == rhs.fields.count else { return false }
        for (a, b) in zip(lhs.fields, rhs.fields) where a.name != b.name || a.value != b.value {
            return false
        }
        return true
    }

    public subscript(name: String) -> [String] {
        fields.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }

    // Serializes to the exact byte format expected inside a FLAC VORBIS_COMMENT
    // metadata block. Matches the layout documented in parse().
    public func encoded() -> Data {
        var out = Data()
        func appendLE(_ v: UInt32) {
            out.append(UInt8(v & 0xff))
            out.append(UInt8((v >> 8) & 0xff))
            out.append(UInt8((v >> 16) & 0xff))
            out.append(UInt8((v >> 24) & 0xff))
        }
        let vendorBytes = Data(vendor.utf8)
        appendLE(UInt32(vendorBytes.count))
        out.append(vendorBytes)
        appendLE(UInt32(fields.count))
        for (name, value) in fields {
            let entry = Data("\(name)=\(value)".utf8)
            appendLE(UInt32(entry.count))
            out.append(entry)
        }
        return out
    }

    static func parse(_ data: Data) throws(FLACError) -> VorbisComment {
        var cursor = 0
        func readUInt32LE() throws(FLACError) -> UInt32 {
            guard cursor + 4 <= data.count else {
                throw .invalidVorbisComment(reason: "truncated at offset \(cursor)")
            }
            let value = data.withUnsafeBytes { raw -> UInt32 in
                let base = raw.baseAddress!.advanced(by: cursor)
                var v: UInt32 = 0
                memcpy(&v, base, 4)
                return UInt32(littleEndian: v)
            }
            cursor += 4
            return value
        }
        func readBytes(_ n: Int) throws(FLACError) -> Data {
            guard cursor + n <= data.count else {
                throw .invalidVorbisComment(reason: "truncated string at offset \(cursor)")
            }
            let slice = data.subdata(in: cursor..<(cursor + n))
            cursor += n
            return slice
        }

        let vendorLen = try readUInt32LE()
        let vendorData = try readBytes(Int(vendorLen))
        guard let vendor = String(data: vendorData, encoding: .utf8) else {
            throw .invalidVorbisComment(reason: "vendor is not valid UTF-8")
        }

        let count = try readUInt32LE()
        var fields: [(String, String)] = []
        fields.reserveCapacity(Int(count))
        for _ in 0..<count {
            let len = try readUInt32LE()
            let bytes = try readBytes(Int(len))
            guard let entry = String(data: bytes, encoding: .utf8) else {
                throw .invalidVorbisComment(reason: "comment is not valid UTF-8")
            }
            guard let eq = entry.firstIndex(of: "=") else {
                throw .invalidVorbisComment(reason: "comment missing '=': \(entry)")
            }
            let name = String(entry[..<eq])
            let value = String(entry[entry.index(after: eq)...])
            fields.append((name, value))
        }
        return VorbisComment(vendor: vendor, fields: fields)
    }
}
