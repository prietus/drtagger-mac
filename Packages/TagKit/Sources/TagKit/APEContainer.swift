import CryptoKit
import FLACKit
import Foundation

// APEv2 (Monkey's Audio, WavPack, TTA): a tag at the end of the file with
// a header and a footer, possibly followed by an ID3v1 tag that we drop.
enum APEContainer {

    struct Item: Equatable { let key: String; let flags: UInt32; let value: Data
        var isText: Bool { (flags >> 1) & 3 == 0 }
        var isBinary: Bool { (flags >> 1) & 3 == 1 }
    }

    struct Layout { let items: [Item]; let tagStart: UInt64; let audioLength: UInt64; let raw: Data }

    static let keyMap: [(key: String, field: String)] = [
        ("Title", TagField.title), ("Artist", TagField.artist), ("Artists", TagField.artists), ("Album", TagField.album),
        ("Album Artist", TagField.albumArtist), ("Year", TagField.date), ("Original Date", TagField.originalDate),
        ("Track", TagField.trackNumber), ("Disc", TagField.discNumber), ("Genre", TagField.genre), ("Composer", TagField.composer),
        ("Lyricist", TagField.lyricist), ("Conductor", TagField.conductor), ("Comment", TagField.comment), ("ISRC", TagField.isrc),
        ("CatalogNumber", TagField.catalogNumber), ("Barcode", TagField.barcode), ("Label", TagField.label), ("Media", TagField.media),
        ("DiscSubtitle", TagField.discSubtitle), ("MixArtist", TagField.remixer), ("Arranger", TagField.arranger),
        ("Producer", TagField.producer), ("Engineer", TagField.engineer), ("Mixer", TagField.mixer), ("Performer", TagField.performer),
        ("Writer", TagField.writer), ("Work", TagField.work), ("Script", TagField.script), ("Compilation", TagField.compilation),
        ("ArtistSort", TagField.artistSort), ("AlbumSort", TagField.albumSort), ("AlbumArtistSort", TagField.albumArtistSort),
        ("ComposerSort", TagField.composerSort), ("Style", TagField.style), ("ReleaseCountry", TagField.releaseCountry),
        ("ReleaseStatus", TagField.releaseStatus), ("ReleaseType", TagField.releaseType),
    ]

    static func layout(_ source: any FLACDataSource) throws -> Layout {
        let total = try source.length
        var end = total
        if total >= 128 {
            let tail = try source.read(at: total - 128, length: 3)
            if tail.ascii(0, 3) == "TAG" { end = total - 128 }
        }
        func bare() throws -> Layout {
            Layout(items: [], tagStart: end, audioLength: end, raw: end < total ? try source.read(at: end, length: Int(total - end)) : Data())
        }
        guard end >= 32 else { return try bare() }
        let footer = try source.read(at: end - 32, length: 32)
        guard footer.ascii(0, 8) == "APETAGEX" else { return try bare() }
        let size = UInt64(footer.u32LE(12)), count = Int(footer.u32LE(16)), flags = footer.u32LE(20)
        let hasHeader = flags & 0x8000_0000 != 0
        let itemsStart = end - size
        let tagStart = hasHeader ? itemsStart - 32 : itemsStart
        guard tagStart <= end, size >= 32 else { throw TagFileError.malformed("APE tag size") }
        let raw = try source.read(at: tagStart, length: Int(total - tagStart))   // tag plus any ID3v1 after it
        var items: [Item] = []
        let body = try source.read(at: itemsStart, length: Int(size - 32))
        var c = 0
        for _ in 0..<count {
            guard c + 8 <= body.count else { break }
            let len = Int(body.u32LE(c)), fl = body.u32LE(c + 4); c += 8
            guard let nul = body[(body.startIndex + c)...].firstIndex(of: 0) else { break }
            let key = String(decoding: body[(body.startIndex + c)..<nul], as: UTF8.self)
            c = nul - body.startIndex + 1
            guard c + len <= body.count else { break }
            items.append(Item(key: key, flags: fl, value: body.subdata(in: (body.startIndex + c)..<(body.startIndex + c + len))))
            c += len
        }
        return Layout(items: items, tagStart: tagStart, audioLength: tagStart, raw: raw)
    }

    static func read(url: URL) throws -> ContainerContents {
        let source = try FileHandleDataSource(url: url)
        let l = try layout(source)
        var tags = TagSet()
        var pictures: [Picture] = []
        var opaque = Data()
        let fieldByKey = Dictionary(keyMap.map { ($0.key.lowercased(), $0.field) }, uniquingKeysWith: { a, _ in a })
        var trackTotal: String?, discTotal: String?
        for item in l.items {
            if item.isText {
                let field = fieldByKey[item.key.lowercased()] ?? item.key.uppercased()
                for v in String(decoding: item.value, as: UTF8.self).split(separator: "\0").map(String.init) {
                    if field == TagField.trackNumber || field == TagField.discNumber, v.contains("/") {
                        let parts = v.split(separator: "/", maxSplits: 1).map(String.init)
                        tags.add(field, parts[0])
                        if field == TagField.trackNumber { trackTotal = parts.last } else { discTotal = parts.last }
                    } else {
                        tags.add(field, v)
                    }
                }
            } else if item.isBinary, item.key.lowercased().hasPrefix("cover art"), let nul = item.value.firstIndex(of: 0) {
                let data = item.value[(nul + 1)...]
                let kind: Picture.Kind = item.key.lowercased().contains("back") ? .back : .front
                let dims = ArtworkProcessor.dimensions(of: Data(data)) ?? (0, 0)
                pictures.append(Picture(kind: kind, mimeType: ArtworkProcessor.mimeType(of: Data(data)) ?? "image/jpeg", data: Data(data), width: dims.0, height: dims.1))
            } else {
                opaque.append(encode(item))
            }
        }
        if let t = trackTotal { tags.set(TagField.trackTotal, t); tags.set(TagField.totalTracks, t) }
        if let d = discTotal { tags.set(TagField.discTotal, d); tags.set(TagField.totalDiscs, d) }
        let digest = try AudioCopier.digest(of: source, offset: 0, length: l.audioLength)
        return ContainerContents(tags: tags, pictures: pictures, rawMetadata: l.raw, audioDigest: digest, opaque: opaque)
    }

    static func write(url: URL, tags: TagSet, pictures: [Picture]?, to out: FileHandle) throws -> String {
        let contents = try read(url: url)
        var items: [Item] = []
        var used = Set<String>()
        func text(_ key: String, _ values: [String]) {
            guard !values.isEmpty else { return }
            items.append(Item(key: key, flags: 0, value: Data(values.joined(separator: "\0").utf8)))
        }
        for (key, field) in keyMap where !tags[field].isEmpty {
            var values = tags[field]
            if field == TagField.trackNumber, let total = tags.first(TagField.trackTotal) ?? tags.first(TagField.totalTracks) { values = ["\(values[0])/\(total)"] }
            if field == TagField.discNumber, let total = tags.first(TagField.discTotal) ?? tags.first(TagField.totalDiscs) { values = ["\(values[0])/\(total)"] }
            text(key, values); used.insert(field)
        }
        used.formUnion([TagField.trackTotal, TagField.totalTracks, TagField.discTotal, TagField.totalDiscs])
        for name in tags.names where !used.contains(name) { text(name, tags[name]) }
        for p in pictures ?? contents.pictures {
            var v = Data("cover.\(p.fileExtension)".utf8); v.append(0); v.append(p.data)
            items.append(Item(key: p.kind == .back ? "Cover Art (Back)" : "Cover Art (Front)", flags: 1 << 1, value: v))
        }
        var tag = Data()
        for item in items { tag.append(encode(item)) }
        if !contents.opaque.isEmpty { tag.append(contents.opaque) }
        let count = UInt32(items.count + countItems(contents.opaque))
        let size = UInt32(tag.count + 32)
        func frame(isHeader: Bool) -> Data {
            var d = Data("APETAGEX".utf8)
            d.appendU32LE(2000); d.appendU32LE(size); d.appendU32LE(count)
            d.appendU32LE(0x8000_0000 | (isHeader ? 0x2000_0000 : 0))
            d.append(Data(count: 8))
            return d
        }
        let source = try FileHandleDataSource(url: url)
        let l = try layout(source)
        var hasher = SHA256()
        try AudioCopier.copy(from: source, offset: 0, length: l.audioLength, to: out, hasher: &hasher)
        if !items.isEmpty || !contents.opaque.isEmpty {
            try out.write(contentsOf: frame(isHeader: true)); try out.write(contentsOf: tag); try out.write(contentsOf: frame(isHeader: false))
        }
        return hasher.hex
    }

    static func restore(url: URL, rawMetadata: Data, to out: FileHandle) throws -> String {
        let source = try FileHandleDataSource(url: url)
        let l = try layout(source)
        var hasher = SHA256()
        try AudioCopier.copy(from: source, offset: 0, length: l.audioLength, to: out, hasher: &hasher)
        try out.write(contentsOf: rawMetadata)
        return hasher.hex
    }

    static func encode(_ item: Item) -> Data {
        var d = Data(); d.appendU32LE(UInt32(item.value.count)); d.appendU32LE(item.flags)
        d.append(Data(item.key.utf8)); d.append(0); d.append(item.value)
        return d
    }

    static func countItems(_ blob: Data) -> Int {
        var c = 0, n = 0
        while c + 8 <= blob.count {
            let len = Int(blob.u32LE(c)); c += 8
            guard let nul = blob[(blob.startIndex + c)...].firstIndex(of: 0) else { break }
            c = nul - blob.startIndex + 1 + len; n += 1
        }
        return n
    }
}
