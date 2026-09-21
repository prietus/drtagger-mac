import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import ProviderKit
import Testing
import UniformTypeIdentifiers
@testable import TagKit

enum Fixtures {
    static let repo: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u = u.deletingLastPathComponent() }
        return u
    }()
    static var ffmpeg: URL? {
        let f = repo.appending(path: "Vendor/ffmpeg/ffmpeg")
        return FileManager.default.isExecutableFile(atPath: f.path) ? f : nil
    }

    static func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "TagKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    // 0.2 s of a 440 Hz tone, 16-bit stereo 44.1 kHz.
    static func wav() -> Data {
        let rate = 44100, frames = rate / 5
        var pcm = Data(capacity: frames * 4)
        for i in 0..<frames {
            let v = Int16(sin(Double(i) / Double(rate) * 440 * 2 * .pi) * 12000)
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { pcm.append(contentsOf: $0); pcm.append(contentsOf: $0) }
        }
        var d = Data("RIFF".utf8); d.appendU32LE(UInt32(36 + pcm.count)); d.append(Data("WAVE".utf8))
        d.append(Data("fmt ".utf8)); d.appendU32LE(16); d.append(contentsOf: [1, 0, 2, 0]); d.appendU32LE(UInt32(rate)); d.appendU32LE(UInt32(rate * 4)); d.append(contentsOf: [4, 0, 16, 0])
        d.append(Data("data".utf8)); d.appendU32LE(UInt32(pcm.count)); d.append(pcm)
        return d
    }

    // Minimal DSF: DSD + fmt + data chunks, no tag.
    static func dsf() -> Data {
        let audio = Data((0..<(4096 * 2 * 3)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        var d = Data("DSD ".utf8); d.appendU64LE(28); d.appendU64LE(UInt64(28 + 52 + 12 + audio.count)); d.appendU64LE(0)
        d.append(Data("fmt ".utf8)); d.appendU64LE(52); d.appendU32LE(1); d.appendU32LE(0); d.appendU32LE(2); d.appendU32LE(2)
        d.appendU32LE(2_822_400); d.appendU32LE(1); d.appendU64LE(UInt64(audio.count / 2 * 8)); d.appendU32LE(4096); d.appendU32LE(0)
        d.append(Data("data".utf8)); d.appendU64LE(UInt64(12 + audio.count)); d.append(audio)
        return d
    }

    // Minimal DSDIFF: FRM8 / DSD  with FVER, PROP and DSD chunks.
    static func dff() -> Data {
        let audio = Data((0..<3000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        var body = Data("DSD ".utf8)
        body.append(Data("FVER".utf8)); body.appendU64BE(4); body.appendU32BE(0x01050000)
        var prop = Data("SND ".utf8); prop.append(Data("FS  ".utf8)); prop.appendU64BE(4); prop.appendU32BE(2_822_400)
        body.append(Data("PROP".utf8)); body.appendU64BE(UInt64(prop.count)); body.append(prop)
        body.append(Data("DSD ".utf8)); body.appendU64BE(UInt64(audio.count)); body.append(audio)
        var d = Data("FRM8".utf8); d.appendU64BE(UInt64(body.count)); d.append(body)
        return d
    }

    static func run(_ tool: URL, _ args: [String]) throws {
        let p = Process(); p.executableURL = tool; p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw CocoaError(.executableRuntimeMismatch) }
    }

    static func image(width: Int, height: Int, png: Bool = false) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, (png ? UTType.png : UTType.jpeg).identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); CGImageDestinationFinalize(dest)
        return out as Data
    }

    static func sha(_ url: URL) throws -> String { SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined() }
}

@Suite("Mapping") struct MappingTests {
    static let candidate = Candidate(
        source: .musicbrainz, providerID: "rel-1", releaseGroupID: "rg-1", title: "Kind of Blue", artist: "Miles Davis", year: "1997", country: "US",
        label: "Columbia, Legacy", catalogNumber: "CK 64935, 64935", mediaFormat: "CD", trackCount: 2, releasedDate: "1997-03-25", barcode: "074646493526",
        media: [CandidateMedium(position: 1, format: "CD", title: nil, tracks: [
            CandidateTrack(position: 1, title: "So What", durationMS: 562000, credits: [TrackCredit(role: "trumpet", name: "Miles Davis"), TrackCredit(role: "producer", name: "Teo Macero"), TrackCredit(role: "composer", name: "Miles Davis")],
                           recordingID: "rec-1", trackID: "trk-1", isrcs: ["USSM15900001"], works: [WorkCredit(id: "work-1", title: "So What")]),
            CandidateTrack(position: 2, title: "Freddie Freeloader", durationMS: 583000, recordingID: "rec-2", trackID: "trk-2"),
        ])],
        status: "Official", primaryType: "Album",
        artistCredits: [ArtistCredit(name: "Miles Davis", artistID: "art-1", sortName: "Davis, Miles")],
        secondaryTypes: [], firstReleaseDate: "1959-08-17", script: "Latn"
    )

    @Test func picardFieldsForATrack() throws {
        var ctx = TagContext()
        ctx.musicBrainzDiscID = "disc-1"
        ctx.acoustIDs = [0: "acoust-1"]
        ctx.discogs = Candidate(source: .discogs, providerID: "d1", title: "Kind of Blue", artist: "Miles Davis",
                                tracks: [CandidateTrack(position: 1, title: "So What", credits: [TrackCredit(role: "Bass", name: "Paul Chambers"), TrackCredit(role: "Written-By", name: "Miles Davis")]),
                                         CandidateTrack(position: 2, title: "Freddie Freeloader")],
                                genres: ["Jazz"], styles: ["Modal"])
        let t = try #require(PicardMapper.trackTags(Self.candidate, media: Self.candidate.media, index: 0, context: ctx))
        #expect(t.first(TagField.title) == "So What")
        #expect(t.first(TagField.artist) == "Miles Davis")
        #expect(t.first(TagField.artistSort) == "Davis, Miles")
        #expect(t.first(TagField.albumArtistSort) == "Davis, Miles")
        #expect(t.first(TagField.date) == "1997-03-25")
        #expect(t.first(TagField.originalDate) == "1959-08-17")
        #expect(t.first(TagField.originalYear) == "1959")
        #expect(t[TagField.label] == ["Columbia", "Legacy"])
        #expect(t[TagField.catalogNumber] == ["CK 64935", "64935"])
        #expect(t.first(TagField.trackNumber) == "1" && t.first(TagField.trackTotal) == "2" && t.first(TagField.discNumber) == "1" && t.first(TagField.discTotal) == "1")
        #expect(t.first(TagField.mbAlbumID) == "rel-1" && t.first(TagField.mbTrackID) == "rec-1" && t.first(TagField.mbReleaseTrackID) == "trk-1")
        #expect(t[TagField.mbArtistID] == ["art-1"] && t[TagField.mbAlbumArtistID] == ["art-1"])
        #expect(t.first(TagField.mbDiscID) == "disc-1")
        #expect(t.first(TagField.releaseStatus) == "official" && t[TagField.releaseType] == ["album"])
        #expect(t[TagField.isrc] == ["USSM15900001"])
        #expect(t[TagField.work] == ["So What"] && t[TagField.mbWorkID] == ["work-1"])
        #expect(t[TagField.performer].contains("Miles Davis (trumpet)"))
        #expect(t[TagField.performer].contains("Paul Chambers (bass)"), "Discogs credits merged")
        #expect(t[TagField.producer] == ["Teo Macero"])
        #expect(t[TagField.composer] == ["Miles Davis"] && t[TagField.writer] == ["Miles Davis"])
        #expect(t[TagField.genre] == ["Jazz"] && t[TagField.style] == ["Modal"])
        #expect(t.first(TagField.acoustID) == "acoust-1")
        #expect(t[TagField.acoustIDFingerprint].isEmpty)
        let second = try #require(PicardMapper.trackTags(Self.candidate, media: Self.candidate.media, index: 1, context: ctx))
        #expect(second.first(TagField.trackNumber) == "2" && second[TagField.performer].isEmpty)
        #expect(PicardMapper.trackTags(Self.candidate, media: Self.candidate.media, index: 2, context: ctx) == nil)
        #expect(PicardMapper.normalizedRole("Guitar [Acoustic]") == "acoustic guitar")
    }

    @Test func mergeReplacesClearsAndLocks() {
        var existing = TagSet()
        existing.set(TagField.title, "so what (old)"); existing.set(TagField.mbAlbumID, "stale-release"); existing.set("REPLAYGAIN_TRACK_GAIN", "-6.1 dB")
        existing.set(TagField.composer, "Somebody"); existing.set(TagField.comment, "keep me")
        var proposed = TagSet()
        proposed.set(TagField.title, "So What"); proposed.set(TagField.artist, "Miles Davis")
        let (result, changes) = TagMerge.merge(existing: existing, proposed: proposed, locked: [TagField.comment, "title"])
        #expect(result.first(TagField.title) == "so what (old)", "locked field untouched")
        #expect(result.first(TagField.artist) == "Miles Davis")
        #expect(result[TagField.mbAlbumID].isEmpty, "identity field the candidate lacks is cleared")
        #expect(result.first("REPLAYGAIN_TRACK_GAIN") == "-6.1 dB", "unmapped field preserved")
        #expect(result.first(TagField.composer) == "Somebody", "credit field preserved when absent")
        #expect(changes.first { $0.name == TagField.mbAlbumID }?.kind == .removed)
        #expect(changes.first { $0.name == TagField.artist }?.kind == .added)
        #expect(changes.first { $0.name == TagField.title }?.kind == .unchanged)
    }

    @Test func artworkIsResizedToJPEG() throws {
        let big = Fixtures.image(width: 2400, height: 2000)
        let p = try ArtworkProcessor.prepared(from: big, maxPixels: 1500)
        #expect(p.mimeType == "image/jpeg" && p.width == 1500 && p.height == 1250)
        let small = Fixtures.image(width: 500, height: 500, png: true)
        #expect(try ArtworkProcessor.prepared(from: small, maxPixels: 1500).mimeType == "image/png")
    }
}

@Suite("Containers", .serialized) struct ContainerTests {

    static func sampleTags() -> TagSet {
        var t = TagSet()
        t.set(TagField.title, "So What"); t.set(TagField.artist, "Miles Davis"); t.set(TagField.album, "Kind of Blue")
        t.set(TagField.albumArtist, "Miles Davis"); t.set(TagField.date, "1997-03-25"); t.set(TagField.originalDate, "1959-08-17")
        t.set(TagField.trackNumber, "1"); t.set(TagField.trackTotal, "2"); t.set(TagField.discNumber, "1"); t.set(TagField.discTotal, "1")
        t[TagField.label] = ["Columbia", "Legacy"]; t.set(TagField.catalogNumber, "CK 64935"); t.set(TagField.barcode, "074646493526")
        t.set(TagField.mbAlbumID, "rel-1"); t.set(TagField.mbTrackID, "rec-1"); t.set(TagField.mbReleaseTrackID, "trk-1")
        t[TagField.performer] = ["Miles Davis (trumpet)", "Paul Chambers (bass)"]; t.set(TagField.producer, "Teo Macero")
        t.set(TagField.isrc, "USSM15900001"); t.set("REPLAYGAIN_TRACK_GAIN", "-6.10 dB"); t.set(TagField.comment, "Ünïcödé — ok")
        return t
    }

    static let checked = [TagField.title, TagField.artist, TagField.album, TagField.albumArtist, TagField.date, TagField.trackNumber, TagField.trackTotal,
                          TagField.discNumber, TagField.label, TagField.catalogNumber, TagField.barcode, TagField.mbAlbumID, TagField.mbTrackID,
                          TagField.mbReleaseTrackID, TagField.performer, TagField.producer, TagField.isrc, "REPLAYGAIN_TRACK_GAIN", TagField.comment]

    func roundTrip(_ url: URL) throws {
        let originalBytes = try Fixtures.sha(url)
        let before = try TaggedFile.read(url)
        let backup = try TaggedFile.backup(url)
        let cover = try ArtworkProcessor.prepared(from: Fixtures.image(width: 600, height: 600), maxPixels: 1500)
        let tags = Self.sampleTags()
        let report = try TaggedFile.write(url, tags: tags, pictures: [cover])
        #expect(report.audioDigest == before.audioDigest)

        let after = try TaggedFile.read(url)
        #expect(after.audioDigest == before.audioDigest, "\(url.pathExtension): audio bytes changed")
        for name in Self.checked {
            #expect(after.tags[name] == tags[name], "\(url.pathExtension): \(name) = \(after.tags[name]) vs \(tags[name])")
        }
        #expect(after.pictures.count == 1 && after.pictures.first?.data == cover.data && after.pictures.first?.isFront == true, "\(url.pathExtension): picture")

        // A second write with pictures: nil keeps the cover; [] drops it.
        var edited = tags; edited.set(TagField.title, "So What (edit)")
        try TaggedFile.write(url, tags: edited)
        #expect(try TaggedFile.read(url).pictures.count == 1)
        try TaggedFile.write(url, tags: edited, pictures: [])
        let stripped = try TaggedFile.read(url)
        #expect(stripped.pictures.isEmpty && stripped.tags.first(TagField.title) == "So What (edit)")
        #expect(stripped.audioDigest == before.audioDigest)

        // Restore puts the original file back byte for byte.
        try TaggedFile.restore(url, from: backup)
        #expect(try Fixtures.sha(url) == originalBytes, "\(url.pathExtension): restore is not byte-exact")
    }

    @Test func wav() throws {
        let dir = try Fixtures.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "t.wav"); try Fixtures.wav().write(to: url)
        try roundTrip(url)
    }

    @Test func flac() throws {
        guard let ffmpeg = Fixtures.ffmpeg else { return }
        let dir = try Fixtures.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appending(path: "t.wav"); try Fixtures.wav().write(to: wav)
        let url = dir.appending(path: "t.flac")
        try Fixtures.run(ffmpeg, ["-loglevel", "quiet", "-i", wav.path, "-metadata", "title=old", "-metadata", "REPLAYGAIN_TRACK_GAIN=-6.10 dB", url.path])
        #expect(try TaggedFile.read(url).tags.first(TagField.title) == "old")
        try roundTrip(url)
    }

    @Test func aiffAndALAC() throws {
        let afconvert = URL(fileURLWithPath: "/usr/bin/afconvert")
        guard FileManager.default.isExecutableFile(atPath: afconvert.path) else { return }
        let dir = try Fixtures.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appending(path: "t.wav"); try Fixtures.wav().write(to: wav)
        let aiff = dir.appending(path: "t.aiff")
        try Fixtures.run(afconvert, ["-f", "AIFF", "-d", "BEI16", wav.path, aiff.path])
        try roundTrip(aiff)
        let m4a = dir.appending(path: "t.m4a")
        try Fixtures.run(afconvert, ["-f", "m4af", "-d", "alac", wav.path, m4a.path])
        try roundTrip(m4a)
        // The moov must still be readable by the OS after our rewrite.
        try TaggedFile.write(m4a, tags: Self.sampleTags())
        let probe = Process(); probe.executableURL = afconvert; probe.arguments = ["-f", "WAVE", "-d", "LEI16", m4a.path, dir.appending(path: "back.wav").path]
        probe.standardError = FileHandle.nullDevice; try probe.run(); probe.waitUntilExit()
        #expect(probe.terminationStatus == 0, "afconvert cannot decode the rewritten m4a")
    }

    @Test func dsfAndDFF() throws {
        let dir = try Fixtures.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let dsf = dir.appending(path: "t.dsf"); try Fixtures.dsf().write(to: dsf)
        try roundTrip(dsf)
        let dff = dir.appending(path: "t.dff"); try Fixtures.dff().write(to: dff)
        try roundTrip(dff)
    }

    @Test func apev2() throws {
        let dir = try Fixtures.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "t.wv")
        var fake = Data("wvpk".utf8); fake.append(Data((0..<5000).map { UInt8(truncatingIfNeeded: $0 &* 13) }))
        fake.append(Data("TAG".utf8)); fake.append(Data(count: 125))     // a stray ID3v1 that must be dropped
        try fake.write(to: url)
        let before = try TaggedFile.read(url)
        let backup = try TaggedFile.backup(url)
        try TaggedFile.write(url, tags: Self.sampleTags(), pictures: [try ArtworkProcessor.prepared(from: Fixtures.image(width: 300, height: 300), maxPixels: 1500)])
        let after = try TaggedFile.read(url)
        #expect(after.audioDigest == before.audioDigest)
        for name in Self.checked { #expect(after.tags[name] == Self.sampleTags()[name], "\(name)") }
        #expect(after.pictures.count == 1)
        let bytes = try Data(contentsOf: url)
        #expect(bytes.count >= 32 && bytes.suffix(32).prefix(8) == Data("APETAGEX".utf8))
        try TaggedFile.restore(url, from: backup)
        #expect(try Data(contentsOf: url) == fake)
    }

    @Test func realDSFSampleIfPresent() throws {
        let sample = URL(fileURLWithPath: NSString(string: "~/mactagger-samples/loose/03 Derek & The Dominos - Key To The Highway.dsf").expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: sample.path) else { return }
        // The local copy may be incomplete (declared size beyond EOF): skip it then.
        let head = try FileHandle(forReadingFrom: sample).read(upToCount: 28) ?? Data()
        let size = (try? sample.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard head.count == 28, head.u64LE(12) <= UInt64(size) else { return }
        let dir = try Fixtures.tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "real.dsf")
        try FileManager.default.copyItem(at: sample, to: url)
        let before = try TaggedFile.read(url)
        print("real DSF tags:", before.tags.pairs.prefix(8).map { "\($0.name)=\($0.value)" }, "pictures:", before.pictures.map { "\($0.width)x\($0.height)" })
        try roundTrip(url)
    }
}
