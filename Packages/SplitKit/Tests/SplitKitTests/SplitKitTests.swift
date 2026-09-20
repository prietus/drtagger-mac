import CryptoKit
import FLACKit
import Foundation
import LibraryKit
import Testing
@testable import SplitKit

// Locates the embedded ffmpeg build (Vendor/ffmpeg) or a Homebrew one.
enum TestTools {
    static var ffmpeg: FFmpegTool? {
        let here = URL(fileURLWithPath: #filePath)
        let repo = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let vendored = repo.appending(path: "Vendor/ffmpeg")
        let candidates = [vendored, URL(fileURLWithPath: "/opt/homebrew/bin"), URL(fileURLWithPath: "/usr/local/bin")]
        for dir in candidates {
            let f = dir.appending(path: "ffmpeg"), p = dir.appending(path: "ffprobe")
            if FileManager.default.isExecutableFile(atPath: f.path), FileManager.default.isExecutableFile(atPath: p.path) {
                return FFmpegTool(ffmpeg: f, ffprobe: p)
            }
        }
        return nil
    }

    static func tempDir(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "splitkit-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // Deterministic pseudo-random PCM so every byte is distinct and any
    // off-by-one shows up in a checksum.
    static func pcm(samples: Int, format: PCMFormat, seed: UInt32 = 1) -> Data {
        var data = Data(capacity: samples * format.bytesPerFrame)
        var state = seed
        for _ in 0..<(samples * format.channels) {
            state = state &* 1664525 &+ 1013904223
            var v = Int32(bitPattern: state)
            switch format.bitsPerSample {
            case 16:
                let s = Int16(truncatingIfNeeded: v >> 16)
                data.append(contentsOf: withUnsafeBytes(of: s.littleEndian) { Array($0) })
            case 24:
                v >>= 8
                data.append(UInt8(truncatingIfNeeded: v))
                data.append(UInt8(truncatingIfNeeded: v >> 8))
                data.append(UInt8(truncatingIfNeeded: v >> 16))
            default:
                data.append(contentsOf: withUnsafeBytes(of: v.littleEndian) { Array($0) })
            }
        }
        return data
    }

    static func writeWAV(_ pcm: Data, format: PCMFormat, to url: URL) throws {
        var d = Data()
        func u32(_ v: UInt32) { d.append(contentsOf: withUnsafeBytes(of: v.littleEndian) { Array($0) }) }
        func u16(_ v: UInt16) { d.append(contentsOf: withUnsafeBytes(of: v.littleEndian) { Array($0) }) }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count)); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1)
        u16(UInt16(format.channels)); u32(UInt32(format.sampleRate))
        u32(UInt32(format.sampleRate * format.bytesPerFrame)); u16(UInt16(format.bytesPerFrame)); u16(UInt16(format.bitsPerSample))
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count)); d.append(pcm)
        try d.write(to: url)
    }

    static func md5Hex(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

@Suite("PathTemplate")
struct PathTemplateTests {
    @Test func rendersAndSanitizes() {
        let values = ["albumartist": "AC/DC", "album": "Back in Black: Remaster", "year": "1980", "track": "01", "title": "Hells Bells"]
        #expect(PathTemplate.render("{albumartist}/{album} ({year})/{track} {title}", values: values) == "AC-DC/Back in Black- Remaster (1980)/01 Hells Bells")
        #expect(PathTemplate.render("{albumartist}/{album} ({year})", values: ["albumartist": "X", "album": "Y"]) == "X/Y")
        #expect(PathTemplate.render("{track} - {title}", values: ["track": "03"]) == "03")
        #expect(PathTemplate.render("{unknown}/{album}", values: ["album": "..Hidden. "]) == "Hidden")
        #expect(PathTemplate.sanitizeComponent("a   b\tc") == "a b c")
    }
}

@Suite("CRC32")
struct CRC32Tests {
    @Test func matchesKnownVector() {
        // CRC32("123456789") is the classic check value.
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF43926)
        var crc = CRC32()
        crc.update(Data("1234".utf8))
        crc.update(Data("56789".utf8))
        #expect(crc.value == 0xCBF43926)
        #expect(UInt32(0xCBF43926).hex8 == "cbf43926")
    }
}

@Suite("ImageSplitter", .serialized)
struct ImageSplitterTests {

    static let cue = """
    PERFORMER "Test Artist"
    TITLE "Test Album"
    REM DATE 2001
    REM GENRE "Jazz"
    FILE "image.wav" WAVE
      TRACK 01 AUDIO
        TITLE "First"
        INDEX 00 00:00:00
        INDEX 01 00:03:00
      TRACK 02 AUDIO
        TITLE "Second / Part"
        PERFORMER "Guest"
        ISRC ABCDE0100002
        INDEX 00 00:06:00
        INDEX 01 00:06:50
      TRACK 03 AUDIO
        TITLE "Third"
        INDEX 01 00:08:00
    """

    private func makeDisc(format: PCMFormat, totalFrames: Int, in dir: URL) throws -> (DetectedDisc, Data) {
        let samples = totalFrames * (format.sampleRate / 75)
        let pcm = TestTools.pcm(samples: samples, format: format)
        try TestTools.writeWAV(pcm, format: format, to: dir.appending(path: "image.wav"))
        let cueURL = dir.appending(path: "image.cue")
        try Data(Self.cue.utf8).write(to: cueURL)
        var disc = DetectedDisc(number: 1, folder: dir)
        disc.cueURL = cueURL
        disc.cue = try CueSheet.parse(url: cueURL)
        disc.imageFile = DetectedTrackFile(url: dir.appending(path: "image.wav"), format: .wav, fileSize: Int64(pcm.count + 44))
        return (disc, pcm)
    }

    @Test func splitsCDImageWithHTOAAndGaps() async throws {
        guard let tool = TestTools.ffmpeg else { return }
        let dir = try TestTools.tempDir("cd")
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = try TestTools.tempDir("out")
        defer { try? FileManager.default.removeItem(at: out) }

        let format = PCMFormat.cd
        let totalFrames = 10 * 75            // 10 s
        let (disc, pcm) = try makeDisc(format: format, totalFrames: totalFrames, in: dir)
        let album = ProvisionalTags.AlbumContext.from(cue: disc.cue!)

        let outcome = try await ImageSplitter(tool: tool).split(disc: disc, album: album, destinationRoot: out)

        #expect(outcome.verified, "warnings: \(outcome.warnings)")
        #expect(outcome.format == format)
        #expect(outcome.outputFolder.path.hasSuffix("Test Artist/Test Album (2001)"))
        #expect(outcome.tracks.map(\.number) == [0, 1, 2, 3])
        #expect(outcome.tracks.map { $0.url.lastPathComponent } == ["00 Hidden Track.flac", "01 First.flac", "02 Second - Part.flac", "03 Third.flac"])

        // Boundaries: HTOA [0,3s), track 1 [3s, 6.667s) includes track 2's pregap, track 2 [6s50f, 8s), track 3 to end.
        let spf: Int64 = 588
        let htoaSamples: Int64 = 3 * 75 * spf
        let firstSamples: Int64 = Int64(6 * 75 + 50 - 3 * 75) * spf
        let secondSamples: Int64 = Int64(8 * 75 - 6 * 75 - 50) * spf
        let thirdSamples: Int64 = Int64(totalFrames - 8 * 75) * spf
        let allSamples: Int64 = Int64(totalFrames) * spf
        #expect(outcome.tracks[0].samples == htoaSamples)
        #expect(outcome.tracks[1].samples == firstSamples)
        #expect(outcome.tracks[2].samples == secondSamples)
        #expect(outcome.tracks[3].samples == thirdSamples)
        let summed: Int64 = outcome.tracks.map(\.samples).reduce(0, +)
        #expect(summed == allSamples)

        // MD5 of fed bytes equals the PCM slice, and STREAMINFO agrees.
        for t in outcome.tracks {
            let start = Int(outcome.plan.tracks.first { $0.number == t.number }!.startSample) * format.bytesPerFrame
            let end = start + Int(t.samples) * format.bytesPerFrame
            #expect(t.md5Hex == TestTools.md5Hex(pcm[start..<end]))
            #expect(t.streamInfoMD5Matches)
            #expect(t.crc32 == CRC32.checksum(pcm[start..<end]))
        }

        // CTDB CRCs: track 1 skips 5880 samples at the start, track 3 skips 5880 at the end.
        let t1 = outcome.plan.numberedTracks[0], t3 = outcome.plan.numberedTracks[2]
        let bpf = format.bytesPerFrame
        let expected1 = CRC32.checksum(pcm[Int(t1.startSample + 5880) * bpf..<Int(t1.endSample) * bpf])
        let expected3 = CRC32.checksum(pcm[Int(t3.startSample) * bpf..<Int(t3.endSample - 5880) * bpf])
        #expect(outcome.tracks[1].ctdbCRC32 == expected1)
        #expect(outcome.tracks[3].ctdbCRC32 == expected3)
        #expect(outcome.tracks[0].ctdbCRC32 == nil)
        #expect(outcome.ctdbDiscCRC32 == CRC32.checksum(pcm[Int(t1.startSample + 5880) * bpf..<Int(t3.endSample - 5880) * bpf]))
        #expect(outcome.ctdbTrackCRC32s?.count == 3)
        #expect(outcome.toc?.trackCount == 3)

        // Provisional tags.
        let second = try FLACFile(url: outcome.tracks[2].url)
        let tags = try #require(second.vorbisComment)
        #expect(tags["TITLE"] == ["Second / Part"])
        #expect(tags["ARTIST"] == ["Guest"])
        #expect(tags["ALBUMARTIST"] == ["Test Artist"])
        #expect(tags["ALBUM"] == ["Test Album"])
        #expect(tags["TRACKNUMBER"] == ["2"])
        #expect(tags["TRACKTOTAL"] == ["3"])
        #expect(tags["DATE"] == ["2001"])
        #expect(tags["GENRE"] == ["Jazz"])
        #expect(tags["ISRC"] == ["ABCDE0100002"])
        #expect(tags["MUSICBRAINZ_DISCID"].first == outcome.toc?.musicBrainzDiscID)
        #expect(tags.vendor == ProvisionalTags.vendor)
        let hidden = try FLACFile(url: outcome.tracks[0].url).vorbisComment
        #expect(hidden?["TITLE"] == ["Hidden Track"])
        #expect(hidden?["TRACKNUMBER"] == ["0"])

        // The audio survived the tag rewrite: STREAMINFO MD5 still matches.
        #expect(second.streamInfo.md5Signature.map { String(format: "%02x", $0) }.joined() == outcome.tracks[2].md5Hex)

        // Refuses to overwrite by default.
        await #expect(throws: SplitError.self) {
            try await ImageSplitter(tool: tool).split(disc: disc, album: album, destinationRoot: out)
        }
        var overwrite = SplitOptions()
        overwrite.overwriteExisting = true
        overwrite.writeProvisionalTags = false
        let again = try await ImageSplitter(tool: tool).split(disc: disc, album: album, destinationRoot: out, options: overwrite)
        #expect(again.verified)
    }

    @Test func splitsHighResolution24Bit() async throws {
        guard let tool = TestTools.ffmpeg else { return }
        let dir = try TestTools.tempDir("hires")
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = try TestTools.tempDir("out24")
        defer { try? FileManager.default.removeItem(at: out) }

        let format = try PCMFormat(sampleRate: 96000, channels: 2, bitsPerSample: 24)
        let (disc, pcm) = try makeDisc(format: format, totalFrames: 10 * 75, in: dir)
        let outcome = try await ImageSplitter(tool: tool).split(disc: disc, album: .from(cue: disc.cue!), destinationRoot: out)

        #expect(outcome.verified, "warnings: \(outcome.warnings)")
        #expect(outcome.warnings.isEmpty, "24-bit STREAMINFO MD5 should match the fed PCM: \(outcome.warnings)")
        #expect(outcome.format == format)
        #expect(outcome.tracks.count == 4)
        #expect(outcome.ctdbDiscCRC32 == nil)          // not CD audio
        #expect(outcome.tracks[1].ctdbCRC32 == nil)
        let flac = try FLACFile(url: outcome.tracks[1].url)
        #expect(flac.streamInfo.bitsPerSample == 24)
        #expect(flac.streamInfo.sampleRate == 96000)
        let start = Int(outcome.plan.tracks[1].startSample) * format.bytesPerFrame
        let end = start + Int(outcome.tracks[1].samples) * format.bytesPerFrame
        #expect(outcome.tracks[1].md5Hex == TestTools.md5Hex(pcm[start..<end]))
    }

    @Test func splitsMultiFileCueWithGapsPrepended() async throws {
        guard let tool = TestTools.ffmpeg else { return }
        let dir = try TestTools.tempDir("multi")
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = try TestTools.tempDir("outm")
        defer { try? FileManager.default.removeItem(at: out) }

        let format = PCMFormat.cd
        let a = TestTools.pcm(samples: 4 * 75 * 588, format: format, seed: 7)
        let b = TestTools.pcm(samples: 5 * 75 * 588, format: format, seed: 9)
        try TestTools.writeWAV(a, format: format, to: dir.appending(path: "01.wav"))
        try TestTools.writeWAV(b, format: format, to: dir.appending(path: "02.wav"))
        let cueText = """
        FILE "01.wav" WAVE
          TRACK 01 AUDIO
            TITLE "A"
            INDEX 01 00:00:00
        FILE "02.wav" WAVE
          TRACK 02 AUDIO
            TITLE "B"
            INDEX 00 00:00:00
            INDEX 01 00:02:00
        """
        let cueURL = dir.appending(path: "d.cue")
        try Data(cueText.utf8).write(to: cueURL)
        var disc = DetectedDisc(number: 1, folder: dir)
        disc.cueURL = cueURL
        disc.cue = try CueSheet.parse(url: cueURL)

        var options = SplitOptions()
        options.albumFolderTemplate = ""
        let outcome = try await ImageSplitter(tool: tool).split(disc: disc, album: ProvisionalTags.AlbumContext(album: "X", albumArtist: "Y"), destinationRoot: out, options: options)

        #expect(outcome.verified, "warnings: \(outcome.warnings)")
        #expect(outcome.outputFolder.standardizedFileURL == out.standardizedFileURL)
        #expect(outcome.tracks.count == 2)
        let aSamples: Int64 = Int64(4 * 75 * 588 + 150 * 588)   // absorbs B's 2 s pregap
        let bSamples: Int64 = Int64(5 * 75 * 588 - 150 * 588)
        #expect(outcome.tracks[0].samples == aSamples)
        #expect(outcome.tracks[1].samples == bSamples)
        var joined = a
        joined.append(b)
        let split = Int(outcome.tracks[0].samples) * format.bytesPerFrame
        #expect(outcome.tracks[0].md5Hex == TestTools.md5Hex(joined[0..<split]))
        #expect(outcome.tracks[1].md5Hex == TestTools.md5Hex(joined[split...]))
    }

    // Real rip end to end; enabled with DRTAGGER_SLOW_TESTS=1 because it
    // encodes 40 minutes of audio. Expected CRCs come from CUETools DB
    // entry 1310779 (confidence 42).
    @Test func realWalkinMatchesCUEToolsDB() async throws {
        guard ProcessInfo.processInfo.environment["DRTAGGER_SLOW_TESTS"] == "1", let tool = TestTools.ffmpeg else { return }
        let folder = URL(fileURLWithPath: NSString(string: "~/mactagger-samples/cue-images/Miles Davis All Stars - Walkin' XRCD").expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        let result = LibraryScanner().scan([folder])
        let album = try #require(result.albums.first)
        let disc = try #require(album.discs.first)
        let out = try TestTools.tempDir("walkin")
        defer { try? FileManager.default.removeItem(at: out) }

        let outcome = try await ImageSplitter(tool: tool).split(disc: disc, album: .from(cue: disc.cue!), destinationRoot: out)
        #expect(outcome.verified, "warnings: \(outcome.warnings)")
        #expect(outcome.tracks.count == 5)
        #expect(outcome.toc?.musicBrainzDiscID == "iOSL4j4VX_YutvVxL4QjWVsVEJE-")
        #expect(outcome.toc?.freeDBDiscID == "3C08E205")
        #expect(outcome.ctdbTrackCRC32s == [0xfe1b0b1d, 0x1b8c2736, 0x30f99024, 0x40265ae9, 0xf52a6619])
        #expect(outcome.ctdbDiscCRC32 == 0x534054fd)
    }
}
