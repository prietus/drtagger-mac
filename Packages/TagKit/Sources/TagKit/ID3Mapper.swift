import FLACKit
import Foundation

// Picard's ID3 conventions: standard text frames where they exist, TXXX
// with Picard's exact descriptions for MusicBrainz identifiers, UFID for
// the recording id, IPLS for people, APIC for pictures. Written as v2.3
// (the dialect every player and DAC front-end reads); v2.4 reads fine.
public enum ID3Mapper {

    static let textFrames: [(frame: String, field: String)] = [
        ("TIT2", TagField.title), ("TPE1", TagField.artist), ("TPE2", TagField.albumArtist), ("TALB", TagField.album),
        ("TSOP", TagField.artistSort), ("TSOA", TagField.albumSort), ("TSO2", TagField.albumArtistSort), ("TSOC", TagField.composerSort),
        ("TCOM", TagField.composer), ("TEXT", TagField.lyricist), ("TPE3", TagField.conductor), ("TPE4", TagField.remixer),
        ("TPUB", TagField.label), ("TMED", TagField.media), ("TSRC", TagField.isrc), ("TCON", TagField.genre),
        ("TSST", TagField.discSubtitle), ("TCMP", TagField.compilation),
        ("TIT1", "GROUPING"), ("TIT3", "SUBTITLE"), ("TBPM", "BPM"), ("TLAN", "LANGUAGE"), ("TCOP", "COPYRIGHT"),
        ("TENC", "ENCODEDBY"), ("TMOO", "MOOD"), ("TOPE", "ORIGINALARTIST"), ("TOAL", "ORIGINALALBUM"), ("TSSE", "ENCODERSETTINGS"),
    ]

    static let txxx: [(description: String, field: String)] = [
        ("MusicBrainz Album Id", TagField.mbAlbumID), ("MusicBrainz Artist Id", TagField.mbArtistID),
        ("MusicBrainz Album Artist Id", TagField.mbAlbumArtistID), ("MusicBrainz Release Group Id", TagField.mbReleaseGroupID),
        ("MusicBrainz Release Track Id", TagField.mbReleaseTrackID), ("MusicBrainz Work Id", TagField.mbWorkID),
        ("MusicBrainz Disc Id", TagField.mbDiscID), ("MusicBrainz Album Type", TagField.releaseType),
        ("MusicBrainz Album Status", TagField.releaseStatus), ("MusicBrainz Album Release Country", TagField.releaseCountry),
        ("Acoustid Id", TagField.acoustID), ("Acoustid Fingerprint", TagField.acoustIDFingerprint),
        ("CATALOGNUMBER", TagField.catalogNumber), ("BARCODE", TagField.barcode), ("SCRIPT", TagField.script),
        ("ARTISTS", TagField.artists), ("WORK", TagField.work), ("Writer", TagField.writer), ("originalyear", TagField.originalYear),
        ("DISCID", TagField.discID), ("STYLE", TagField.style),
    ]

    static let peopleFields: [String: String] = [   // IPLS role → field
        "producer": TagField.producer, "engineer": TagField.engineer, "mixer": TagField.mixer, "mix": TagField.mixer,
        "arranger": TagField.arranger, "DJ-mix": TagField.remixer,
    ]

    public static let ufidOwner = "http://musicbrainz.org"

    // MARK: Read

    public struct Parsed: Sendable {
        public var tags: TagSet
        public var pictures: [Picture]
        public var preserved: [ID3v2Frame]     // frames the schema cannot express, kept raw
    }

    // ID3 puts a BOM in front of every UTF-16 string; drop it after decoding.
    static func clean(_ s: String) -> String {
        s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s
    }

    static func texts(_ payload: Data) -> [String] {
        ID3v2Bridge.decodeTextFrame(payload).map(clean).filter { !$0.isEmpty }
    }

    // TXXX: encoding, description, then one or more NUL-separated values.
    static func decodeTXXX(_ payload: Data) -> (description: String, values: [String])? {
        guard let encoding = payload.first else { return nil }
        let parts = ID3v2Bridge.splitNullTerminated(payload.dropFirst(), encoding: encoding).map(clean)
        guard parts.count >= 2 else { return nil }
        return (parts[0], Array(parts[1...]).filter { !$0.isEmpty })
    }

    public static func parse(_ tag: ID3v2Tag) -> Parsed {
        var tags = TagSet()
        var pictures: [Picture] = []
        var preserved: [ID3v2Frame] = []
        let byFrame = Dictionary(textFrames.map { ($0.frame, $0.field) }, uniquingKeysWith: { a, _ in a })
        let byDescription = Dictionary(txxx.map { ($0.description.lowercased(), $0.field) }, uniquingKeysWith: { a, _ in a })
        var trackTotal: String? = nil, discTotal: String? = nil
        for frame in tag.frames {
            switch frame.id {
            case "APIC":
                if let p = parseAPIC(frame.payload) { pictures.append(p) } else { preserved.append(frame) }
            case "TXXX":
                guard let (desc, values) = decodeTXXX(frame.payload) else { preserved.append(frame); continue }
                let field = byDescription[desc.lowercased()] ?? desc.uppercased()
                for v in values { tags.add(field, v) }
            case "COMM":
                if let c = ID3v2Bridge.decodeCOMM(frame.payload) { tags.add(TagField.comment, clean(c)) }
            case "UFID":
                if let (owner, id) = parseUFID(frame.payload), owner == ufidOwner { tags.set(TagField.mbTrackID, id) } else { preserved.append(frame) }
            case "TRCK":
                let v = texts(frame.payload).first ?? ""
                let parts = v.split(separator: "/", maxSplits: 1).map(String.init)
                tags.set(TagField.trackNumber, parts.first)
                if parts.count > 1 { trackTotal = parts[1] }
            case "TPOS":
                let v = texts(frame.payload).first ?? ""
                let parts = v.split(separator: "/", maxSplits: 1).map(String.init)
                tags.set(TagField.discNumber, parts.first)
                if parts.count > 1 { discTotal = parts[1] }
            case "TYER", "TDRC":
                if let v = texts(frame.payload).first, tags[TagField.date].isEmpty || frame.id == "TDRC" { tags.set(TagField.date, v) }
            case "TDAT":
                if let v = texts(frame.payload).first, v.count == 4, let year = tags.first(TagField.date), year.count == 4 {
                    tags.set(TagField.date, "\(year)-\(v.suffix(2))-\(v.prefix(2))")
                }
            case "TORY", "TDOR":
                if let v = texts(frame.payload).first { tags.set(TagField.originalDate, v) }
            case "IPLS", "TIPL", "TMCL":
                let items = ID3v2Bridge.decodeTextFrame(frame.payload).map(clean)
                var i = 0
                while i + 1 < items.count {
                    let role = items[i], name = items[i + 1]
                    if let field = peopleFields[role] { tags.add(field, name) }
                    else if role.isEmpty || role.lowercased() == "performer" { tags.add(TagField.performer, name) }
                    else { tags.add(TagField.performer, "\(name) (\(role))") }
                    i += 2
                }
            default:
                if let field = byFrame[frame.id] {
                    for v in texts(frame.payload) { tags.add(field, v) }
                } else {
                    preserved.append(frame)
                }
            }
        }
        if let t = trackTotal { tags.set(TagField.trackTotal, t); tags.set(TagField.totalTracks, t) }
        if let d = discTotal { tags.set(TagField.discTotal, d); tags.set(TagField.totalDiscs, d) }
        return Parsed(tags: tags, pictures: pictures, preserved: preserved)
    }

    // MARK: Write

    public static func tag(from tags: TagSet, pictures: [Picture], preserved: [ID3v2Frame]) -> ID3v2Tag {
        var frames: [ID3v2Frame] = []
        var used = Set<String>()
        func text(_ id: String, _ values: [String]) {
            guard !values.isEmpty else { return }
            frames.append(ID3v2Bridge.makeTextFrame(id: id, value: values.joined(separator: "\0")))
        }
        // Multi-valued text frames are NUL-separated (the v2.4 rule; our
        // reader and Picard's split them, older players show the first).
        for (frame, field) in textFrames where !tags[field].isEmpty {
            text(frame, tags[field]); used.insert(field)
        }
        if let n = tags.first(TagField.trackNumber) {
            let total = tags.first(TagField.trackTotal) ?? tags.first(TagField.totalTracks)
            text("TRCK", [total.map { "\(n)/\($0)" } ?? n])
        }
        if let n = tags.first(TagField.discNumber) {
            let total = tags.first(TagField.discTotal) ?? tags.first(TagField.totalDiscs)
            text("TPOS", [total.map { "\(n)/\($0)" } ?? n])
        }
        used.formUnion([TagField.trackNumber, TagField.trackTotal, TagField.totalTracks, TagField.discNumber, TagField.discTotal, TagField.totalDiscs])
        if let date = tags.first(TagField.date) {
            text("TYER", [String(date.prefix(4))])
            if date.count >= 10 { text("TDAT", ["\(date.dropFirst(8).prefix(2))\(date.dropFirst(5).prefix(2))"]) }
            used.insert(TagField.date)
        }
        if let original = tags.first(TagField.originalDate) { text("TORY", [String(original.prefix(4))]); used.insert(TagField.originalDate) }
        for c in tags[TagField.comment] {
            var payload = Data([0x01]); payload.append(contentsOf: Array("eng".utf8))
            payload.append(ID3v2Bridge.encodeUTF16WithBOM("")); payload.append(contentsOf: [0, 0]); payload.append(ID3v2Bridge.encodeUTF16WithBOM(c))
            frames.append(ID3v2Frame(id: "COMM", payload: payload))
        }
        used.insert(TagField.comment)
        if let rec = tags.first(TagField.mbTrackID) {
            var payload = Data(ufidOwner.utf8); payload.append(0); payload.append(contentsOf: Array(rec.utf8))
            frames.append(ID3v2Frame(id: "UFID", payload: payload)); used.insert(TagField.mbTrackID)
        }
        // People: producer/engineer/mixer/arranger and performers "Name (role)".
        var people: [String] = []
        for (role, field) in [("producer", TagField.producer), ("engineer", TagField.engineer), ("mixer", TagField.mixer), ("arranger", TagField.arranger)] {
            for name in tags[field] { people += [role, name] }
            used.insert(field)
        }
        for p in tags[TagField.performer] {
            if let open = p.lastIndex(of: "("), p.hasSuffix(")"), open > p.startIndex {
                people += [String(p[p.index(after: open)..<p.index(before: p.endIndex)]), p[..<open].trimmingCharacters(in: .whitespaces)]
            } else {
                people += ["performer", p]
            }
        }
        used.insert(TagField.performer)
        if !people.isEmpty {
            var payload = Data([0x01])
            for (i, s) in people.enumerated() {
                payload.append(ID3v2Bridge.encodeUTF16WithBOM(s))
                if i < people.count - 1 { payload.append(contentsOf: [0, 0]) }
            }
            frames.append(ID3v2Frame(id: "IPLS", payload: payload))
        }
        for (description, field) in txxx where !tags[field].isEmpty {
            frames.append(ID3v2Bridge.makeTXXXFrame(description: description, value: tags[field].joined(separator: "\0")))
            used.insert(field)
        }
        for name in tags.names where !used.contains(name) {
            frames.append(ID3v2Bridge.makeTXXXFrame(description: name, value: tags[name].joined(separator: "\0")))
        }
        for p in pictures { frames.append(apic(p)) }
        frames.append(contentsOf: preserved)
        return ID3v2Tag(frames: frames)
    }

    // MARK: APIC / UFID

    static func apic(_ p: Picture) -> ID3v2Frame {
        var payload = Data([0x00])                       // ISO-8859-1 for the mime/description
        payload.append(contentsOf: Array(p.mimeType.utf8)); payload.append(0)
        payload.append(UInt8(p.kind.rawValue))
        payload.append(contentsOf: Array(p.description.utf8.prefix(60))); payload.append(0)
        payload.append(p.data)
        return ID3v2Frame(id: "APIC", payload: payload)
    }

    static func parseAPIC(_ payload: Data) -> Picture? {
        guard payload.count > 4 else { return nil }
        let bytes = [UInt8](payload)
        let encoding = bytes[0]
        guard let mimeEnd = bytes[1...].firstIndex(of: 0) else { return nil }
        let mime = String(decoding: bytes[1..<mimeEnd], as: UTF8.self)
        var cursor = mimeEnd + 1
        guard cursor < bytes.count else { return nil }
        let kind = Picture.Kind(rawValue: Int(bytes[cursor])) ?? .other
        cursor += 1
        // Description: NUL (or double NUL for UTF-16) terminated.
        var descEnd = cursor
        if encoding == 1 || encoding == 2 {
            while descEnd + 1 < bytes.count, !(bytes[descEnd] == 0 && bytes[descEnd + 1] == 0) { descEnd += 2 }
            let desc = ID3v2Bridge.decodeText(Data(bytes[cursor..<min(descEnd, bytes.count)]), encoding: encoding)
            cursor = min(descEnd + 2, bytes.count)
            let data = Data(bytes[cursor...])
            let dims = ArtworkProcessor.dimensions(of: data) ?? (0, 0)
            return Picture(kind: kind, mimeType: mime, data: data, width: dims.0, height: dims.1, description: desc)
        }
        while descEnd < bytes.count, bytes[descEnd] != 0 { descEnd += 1 }
        let desc = String(decoding: bytes[cursor..<descEnd], as: UTF8.self)
        cursor = min(descEnd + 1, bytes.count)
        let data = Data(bytes[cursor...])
        let dims = ArtworkProcessor.dimensions(of: data) ?? (0, 0)
        return Picture(kind: kind, mimeType: mime, data: data, width: dims.0, height: dims.1, description: desc)
    }

    static func parseUFID(_ payload: Data) -> (owner: String, id: String)? {
        guard let nul = payload.firstIndex(of: 0) else { return nil }
        let owner = String(decoding: payload[payload.startIndex..<nul], as: UTF8.self)
        let id = String(decoding: payload[(nul + 1)...], as: UTF8.self)
        return (owner, id)
    }
}
