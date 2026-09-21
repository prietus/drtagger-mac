import CryptoKit
import FLACKit
import Foundation

// MP4/M4A (ALAC): tags in moov/udta/meta/ilst. The rewrite never moves
// mdat: an old moov that sits before the audio is turned into a `free`
// atom of the same size and the new moov is appended, so chunk offsets
// stay valid.
enum MP4Container {

    struct Atom { let type: String; let offset: UInt64; let size: UInt64; let headerSize: Int
        var payloadOffset: UInt64 { offset + UInt64(headerSize) }
        var payloadSize: UInt64 { size - UInt64(headerSize) }
    }

    static let simple: [(atom: String, field: String)] = [
        ("\u{A9}nam", TagField.title), ("\u{A9}ART", TagField.artist), ("aART", TagField.albumArtist), ("\u{A9}alb", TagField.album),
        ("\u{A9}day", TagField.date), ("\u{A9}gen", TagField.genre), ("\u{A9}wrt", TagField.composer), ("\u{A9}cmt", TagField.comment),
        ("\u{A9}grp", "GROUPING"), ("\u{A9}lyr", "LYRICS"), ("soar", TagField.artistSort), ("soaa", TagField.albumArtistSort),
        ("soal", TagField.albumSort), ("soco", TagField.composerSort), ("sonm", "TITLESORT"),
    ]

    static let freeform: [(name: String, field: String)] = [
        ("MusicBrainz Track Id", TagField.mbTrackID), ("MusicBrainz Artist Id", TagField.mbArtistID), ("MusicBrainz Album Id", TagField.mbAlbumID),
        ("MusicBrainz Album Artist Id", TagField.mbAlbumArtistID), ("MusicBrainz Release Group Id", TagField.mbReleaseGroupID),
        ("MusicBrainz Release Track Id", TagField.mbReleaseTrackID), ("MusicBrainz Work Id", TagField.mbWorkID), ("MusicBrainz Disc Id", TagField.mbDiscID),
        ("MusicBrainz Album Status", TagField.releaseStatus), ("MusicBrainz Album Type", TagField.releaseType),
        ("MusicBrainz Album Release Country", TagField.releaseCountry), ("Acoustid Id", TagField.acoustID), ("Acoustid Fingerprint", TagField.acoustIDFingerprint),
        ("CATALOGNUMBER", TagField.catalogNumber), ("BARCODE", TagField.barcode), ("LABEL", TagField.label), ("MEDIA", TagField.media),
        ("ISRC", TagField.isrc), ("ORIGINALDATE", TagField.originalDate), ("ORIGINALYEAR", TagField.originalYear), ("SCRIPT", TagField.script),
        ("ARTISTS", TagField.artists), ("WORK", TagField.work), ("LYRICIST", TagField.lyricist), ("CONDUCTOR", TagField.conductor),
        ("REMIXER", TagField.remixer), ("ENGINEER", TagField.engineer), ("PRODUCER", TagField.producer), ("MIXER", TagField.mixer),
        ("ARRANGER", TagField.arranger), ("PERFORMER", TagField.performer), ("WRITER", TagField.writer), ("DISCSUBTITLE", TagField.discSubtitle),
        ("STYLE", TagField.style), ("DISCID", TagField.discID),
    ]

    // MARK: Atoms

    static func atoms(_ source: any FLACDataSource, from start: UInt64, to end: UInt64) throws -> [Atom] {
        var list: [Atom] = []
        var cursor = start
        while cursor + 8 <= end {
            let h = try source.read(at: cursor, length: 8)
            var size = UInt64(h.u32BE(0))
            let type = String(data: h.subdata(in: 4..<8), encoding: .isoLatin1) ?? "????"
            var headerSize = 8
            if size == 1 {
                guard cursor + 16 <= end else { break }
                size = try source.read(at: cursor + 8, length: 8).u64BE(0); headerSize = 16
            } else if size == 0 {
                size = end - cursor
            }
            guard size >= UInt64(headerSize), cursor + size <= end else { throw TagFileError.malformed("atom \(type) size") }
            list.append(Atom(type: type, offset: cursor, size: size, headerSize: headerSize))
            cursor += size
        }
        return list
    }

    static func children(of atom: Atom, _ source: any FLACDataSource, skip: UInt64 = 0) throws -> [Atom] {
        try atoms(source, from: atom.payloadOffset + skip, to: atom.offset + atom.size)
    }

    static func find(_ type: String, in list: [Atom]) -> Atom? { list.first { $0.type == type } }

    struct Located { let top: [Atom]; let moov: Atom; let udta: Atom?; let meta: Atom?; let ilst: Atom? }

    static func locate(_ source: any FLACDataSource) throws -> Located {
        let top = try atoms(source, from: 0, to: try source.length)
        guard let moov = find("moov", in: top) else { throw TagFileError.malformed("no moov atom") }
        let udta = find("udta", in: try children(of: moov, source))
        let meta = try udta.flatMap { find("meta", in: try children(of: $0, source)) }
        let ilst = try meta.flatMap { find("ilst", in: try children(of: $0, source, skip: 4)) }
        return Located(top: top, moov: moov, udta: udta, meta: meta, ilst: ilst)
    }

    // MARK: Read

    static func read(url: URL) throws -> ContainerContents {
        let source = try FileHandleDataSource(url: url)
        let loc = try locate(source)
        var tags = TagSet()
        var pictures: [Picture] = []
        var opaque = Data()
        let bySimple = Dictionary(simple.map { ($0.atom, $0.field) }, uniquingKeysWith: { a, _ in a })
        let byName = Dictionary(freeform.map { ($0.name.lowercased(), $0.field) }, uniquingKeysWith: { a, _ in a })
        // The whole moov is the backup: a rewrite may have moved it, and
        // restoring puts it back where it was.
        let raw = try source.read(at: loc.moov.offset, length: Int(loc.moov.size))
        if let ilst = loc.ilst {
            for item in try children(of: ilst, source) {
                let kids = try children(of: item, source)
                let datas = kids.filter { $0.type == "data" }
                let bytes = try source.read(at: item.offset, length: Int(item.size))
                switch item.type {
                case "----":
                    let name = try kids.first { $0.type == "name" }.map { String(decoding: try source.read(at: $0.payloadOffset + 4, length: Int($0.payloadSize - 4)), as: UTF8.self) } ?? ""
                    let mean = try kids.first { $0.type == "mean" }.map { String(decoding: try source.read(at: $0.payloadOffset + 4, length: Int($0.payloadSize - 4)), as: UTF8.self) } ?? ""
                    guard mean == "com.apple.iTunes" else { opaque.append(bytes); continue }
                    let field = byName[name.lowercased()] ?? name.uppercased()
                    for d in datas { if let s = try text(d, source) { for v in s.split(separator: "\0").map(String.init) { tags.add(field, v) } } }
                case "trkn", "disk":
                    guard let d = datas.first, d.payloadSize >= 14 else { opaque.append(bytes); continue }
                    let p = try source.read(at: d.payloadOffset + 8, length: Int(d.payloadSize - 8))
                    let n = Int(p.u16BE(2)), total = Int(p.u16BE(4))
                    if item.type == "trkn" {
                        if n > 0 { tags.set(TagField.trackNumber, String(n)) }
                        if total > 0 { tags.set(TagField.trackTotal, String(total)); tags.set(TagField.totalTracks, String(total)) }
                    } else {
                        if n > 0 { tags.set(TagField.discNumber, String(n)) }
                        if total > 0 { tags.set(TagField.discTotal, String(total)); tags.set(TagField.totalDiscs, String(total)) }
                    }
                case "cpil":
                    if let d = datas.first, d.payloadSize >= 9, try source.read(at: d.payloadOffset + 8, length: 1)[0] != 0 { tags.set(TagField.compilation, "1") }
                case "covr":
                    for d in datas {
                        let data = try source.read(at: d.payloadOffset + 8, length: Int(d.payloadSize - 8))
                        let dims = ArtworkProcessor.dimensions(of: data) ?? (0, 0)
                        pictures.append(Picture(kind: pictures.isEmpty ? .front : .other, mimeType: ArtworkProcessor.mimeType(of: data) ?? "image/jpeg", data: data, width: dims.0, height: dims.1))
                    }
                default:
                    if let field = bySimple[item.type] {
                        for d in datas { if let s = try text(d, source) { for v in s.split(separator: "\0").map(String.init) { tags.add(field, v) } } }
                    } else {
                        opaque.append(bytes)
                    }
                }
            }
        }
        let digest = try audioDigest(source, loc.top)
        return ContainerContents(tags: tags, pictures: pictures, rawMetadata: raw, audioDigest: digest, opaque: opaque)
    }

    private static func text(_ data: Atom, _ source: any FLACDataSource) throws -> String? {
        guard data.payloadSize >= 8 else { return nil }
        let head = try source.read(at: data.payloadOffset, length: 8)
        let type = head.u32BE(0) & 0xFF_FFFF
        let body = try source.read(at: data.payloadOffset + 8, length: Int(data.payloadSize - 8))
        switch type {
        case 1: return String(decoding: body, as: UTF8.self)
        case 2: return String(data: body, encoding: .utf16BigEndian)
        case 0, 21, 22: return body.count <= 8 ? String(body.reduce(0) { ($0 << 8) | Int($1) }) : nil
        default: return nil
        }
    }

    private static func audioDigest(_ source: any FLACDataSource, _ top: [Atom]) throws -> String {
        var hasher = SHA256()
        for a in top where a.type == "mdat" {
            try AudioCopier.copy(from: source, offset: a.payloadOffset, length: a.payloadSize, to: nil, hasher: &hasher)
        }
        return hasher.hex
    }

    // MARK: Write

    static func write(url: URL, tags: TagSet, pictures: [Picture]?, to out: FileHandle) throws -> String {
        let contents = try read(url: url)
        var ilst = Data()
        var used = Set<String>()
        func item(_ type: String, datas: [Data]) {
            var body = Data()
            for d in datas { body.append(d) }
            ilst.append(atom(type, body))
        }
        func textData(_ s: String) -> Data { var d = Data(); d.appendU32BE(1); d.appendU32BE(0); d.append(Data(s.utf8)); return atom("data", d) }
        for (type, field) in simple where !tags[field].isEmpty {
            item(type, datas: [textData(tags[field].joined(separator: type == "\u{A9}gen" ? "\0" : "; "))]); used.insert(field)
        }
        func numbers(_ type: String, _ n: String?, _ total: String?) {
            guard let n = n.flatMap(Int.init) else { return }
            var p = Data(); p.appendU32BE(0); p.appendU32BE(0); p.appendU16BE(0); p.appendU16BE(UInt16(clamping: n)); p.appendU16BE(UInt16(clamping: total.flatMap(Int.init) ?? 0)); p.appendU16BE(0)
            item(type, datas: [atom("data", p)])
        }
        numbers("trkn", tags.first(TagField.trackNumber), tags.first(TagField.trackTotal) ?? tags.first(TagField.totalTracks))
        numbers("disk", tags.first(TagField.discNumber), tags.first(TagField.discTotal) ?? tags.first(TagField.totalDiscs))
        used.formUnion([TagField.trackNumber, TagField.trackTotal, TagField.totalTracks, TagField.discNumber, TagField.discTotal, TagField.totalDiscs])
        if tags.first(TagField.compilation) == "1" {
            var p = Data(); p.appendU32BE(21); p.appendU32BE(0); p.append(1); item("cpil", datas: [atom("data", p)])
        }
        used.insert(TagField.compilation)
        for (name, field) in freeform where !tags[field].isEmpty {
            item("----", datas: [meanName("com.apple.iTunes", name)] + tags[field].map(textData)); used.insert(field)
        }
        for name in tags.names where !used.contains(name) {
            item("----", datas: [meanName("com.apple.iTunes", name)] + tags[name].map(textData))
        }
        let pics = pictures ?? contents.pictures
        if !pics.isEmpty {
            item("covr", datas: pics.map { p in var d = Data(); d.appendU32BE(p.mimeType == "image/png" ? 14 : 13); d.appendU32BE(0); d.append(p.data); return atom("data", d) })
        }
        ilst.append(contents.opaque)
        return try emit(url: url, ilstPayload: ilst, to: out)
    }

    // rawMetadata is the original moov atom. If our rewrite left a `free`
    // slot of its size in front of the audio, the moov goes back there and
    // the trailing copy is dropped, which makes the file byte-exact again.
    static func restore(url: URL, rawMetadata: Data, to out: FileHandle) throws -> String {
        let source = try FileHandleDataSource(url: url)
        let loc = try locate(source)
        guard rawMetadata.count >= 8, rawMetadata.ascii(4, 4) == "moov" else { throw TagFileError.malformed("backup is not a moov atom") }
        let slot = loc.top.first { $0.type == "free" && $0.size == UInt64(rawMetadata.count) && $0.offset < loc.moov.offset }
        var hasher = SHA256()
        for a in loc.top {
            if let slot, a.offset == slot.offset { try out.write(contentsOf: rawMetadata); continue }
            if a.type == "moov" {
                if slot == nil { try out.write(contentsOf: rawMetadata) }
                continue
            }
            try out.write(contentsOf: try source.read(at: a.offset, length: a.headerSize))
            if a.type == "mdat" {
                try AudioCopier.copy(from: source, offset: a.payloadOffset, length: a.payloadSize, to: out, hasher: &hasher)
            } else {
                var scratch = SHA256()
                try AudioCopier.copy(from: source, offset: a.payloadOffset, length: a.payloadSize, to: out, hasher: &scratch)
            }
        }
        return hasher.hex
    }

    private static func emit(url: URL, ilstPayload: Data, to out: FileHandle) throws -> String {
        let source = try FileHandleDataSource(url: url)
        let loc = try locate(source)
        // New meta: version/flags + hdlr (existing or a fresh mdir one) + other children + ilst.
        var metaBody = Data()
        var otherMeta = Data()
        var hasHdlr = false
        if let meta = loc.meta {
            metaBody.append(try source.read(at: meta.payloadOffset, length: 4))
            for c in try children(of: meta, source, skip: 4) where c.type != "ilst" {
                if c.type == "hdlr" { hasHdlr = true }
                otherMeta.append(try source.read(at: c.offset, length: Int(c.size)))
            }
        } else {
            metaBody.append(Data(count: 4))
        }
        if !hasHdlr {
            var h = Data(count: 8); h.append(Data("mdirappl".utf8)); h.append(Data(count: 9))
            otherMeta.append(atom("hdlr", h))
        }
        metaBody.append(otherMeta)
        metaBody.append(atom("ilst", ilstPayload))
        let newMeta = atom("meta", metaBody)
        var udtaBody = Data()
        if let udta = loc.udta {
            for c in try children(of: udta, source) where c.type != "meta" { udtaBody.append(try source.read(at: c.offset, length: Int(c.size))) }
        }
        udtaBody.append(newMeta)
        var moovBody = Data()
        for c in try children(of: loc.moov, source) where c.type != "udta" { moovBody.append(try source.read(at: c.offset, length: Int(c.size))) }
        moovBody.append(atom("udta", udtaBody))
        let newMoov = atom("moov", moovBody)

        let mdatOffset = loc.top.first { $0.type == "mdat" }?.offset ?? UInt64.max
        let moovBeforeAudio = loc.moov.offset < mdatOffset
        var hasher = SHA256()
        for a in loc.top {
            if a.type == "moov" {
                if moovBeforeAudio {
                    var free = Data(); free.appendU32BE(UInt32(clamping: a.size)); free.append(Data("free".utf8))
                    try out.write(contentsOf: free)
                    try out.write(contentsOf: Data(count: Int(a.size) - 8))
                } else {
                    try out.write(contentsOf: newMoov)
                }
                continue
            }
            try out.write(contentsOf: try source.read(at: a.offset, length: a.headerSize))
            if a.type == "mdat" {
                try AudioCopier.copy(from: source, offset: a.payloadOffset, length: a.payloadSize, to: out, hasher: &hasher)
            } else {
                var scratch = SHA256()
                try AudioCopier.copy(from: source, offset: a.payloadOffset, length: a.payloadSize, to: out, hasher: &scratch)
            }
        }
        if moovBeforeAudio { try out.write(contentsOf: newMoov) }
        return hasher.hex
    }

    static func atom(_ type: String, _ body: Data) -> Data {
        var d = Data(); d.appendU32BE(UInt32(body.count + 8)); d.append(type.data(using: .isoLatin1) ?? Data("????".utf8)); d.append(body); return d
    }

    static func meanName(_ mean: String, _ name: String) -> Data {
        var m = Data(count: 4); m.append(Data(mean.utf8))
        var n = Data(count: 4); n.append(Data(name.utf8))
        var d = atom("mean", m); d.append(atom("name", n)); return d
    }
}
