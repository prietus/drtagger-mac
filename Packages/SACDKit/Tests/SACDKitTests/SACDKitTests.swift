import FLACKit
import Foundation
import LibraryKit
import Testing
@testable import SACDKit

// Builds a synthetic Scarletbook image with a real audio area: frames are
// packed into 2048-byte sectors the way discs do it (2016 audio bytes per
// sector after a 24-byte supplementary packet, frames starting mid-sector,
// timecodes in the frame table), plus SACDTRL1/2, SACD_IGL and SACDTTxt.
struct FakeDisc {
    struct Track {
        let startFrame: Int
        let durationFrames: Int
        let title: String
        let performer: String?
        let isrc: String?
    }

    let channels: Int
    let tracks: [Track]
    let totalFrames: Int          // frames written to the audio area
    let leadInFrames: Int         // frames before track 1 (2 s on real discs)
    let dst: Bool

    var frameBytes: Int { channels * Scarletbook.bytesPerChannelPerFrame }

    // Deterministic frame content: byte depends on frame index and position.
    static func frameData(index: Int, bytes: Int) -> Data {
        var d = Data(count: bytes)
        d.withUnsafeMutableBytes { raw in
            var x = UInt32(truncatingIfNeeded: index &* 2654435761 &+ 12345)
            for i in 0..<bytes {
                x = x &* 1664525 &+ 1013904223
                raw[i] = UInt8(truncatingIfNeeded: x >> 24)
            }
        }
        return d
    }

    func write(to url: URL, title: String = "Fake Album", artist: String = "Fake Artist") throws {
        let S = Scarletbook.sectorSize
        var image = Data()
        func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        func sectorData(_ builder: (inout Data) -> Void) -> Data {
            var d = Data(count: S)
            builder(&d)
            return d
        }
        func put(_ d: inout Data, _ bytes: [UInt8], at o: Int) { d.replaceSubrange(o..<(o + bytes.count), with: bytes) }

        // --- audio area: pack frames into sectors ---
        var audio = Data()
        var pending = Data()                       // bytes of frames not yet written
        var frameStarts: [(offsetInStream: Int, timecode: SACDTime)] = []
        var streamOffset = 0
        for f in 0..<totalFrames {
            frameStarts.append((streamOffset, SACDTime(totalFrames: f)))
            let d = FakeDisc.frameData(index: f, bytes: frameBytes)
            pending.append(d)
            streamOffset += d.count
        }
        var consumed = 0
        var nextStart = 0
        let audioPerSector = 2016
        while consumed < pending.count {
            let take = min(audioPerSector, pending.count - consumed)
            let chunk = pending[consumed..<(consumed + take)]
            // Frame starts inside this chunk.
            var starts: [Int] = []
            while nextStart < frameStarts.count && frameStarts[nextStart].offsetInStream < consumed + take {
                starts.append(frameStarts[nextStart].offsetInStream - consumed)
                nextStart += 1
            }
            // Audio segments: a segment beginning at a frame start carries the flag.
            var audioPackets: [(Bool, Data)] = []
            var cursor = 0
            var cursorIsStart = false
            for s in starts {
                if s > cursor { audioPackets.append((cursorIsStart, Data(chunk[chunk.startIndex + cursor ..< chunk.startIndex + s]))) }
                cursor = s
                cursorIsStart = true
            }
            audioPackets.append((cursorIsStart, Data(chunk[(chunk.startIndex + cursor)...])))
            let frameInfos = starts.map { s in frameStarts.first { $0.offsetInStream == consumed + s }!.timecode }
            // Like real discs, the supplementary packet shrinks so the sector stays 2048 bytes.
            let headerSize = 1 + 2 * (audioPackets.count + 1) + (dst ? 4 : 3) * frameInfos.count
            let supplementary = S - headerSize - take
            precondition(supplementary >= 0)
            var packets: [(Bool, Int, Data)] = [(false, 3, Data(count: supplementary))]
            packets.append(contentsOf: audioPackets.map { ($0.0, 2, $0.1) })
            var sector = Data()
            sector.append(UInt8(packets.count << 5 | frameInfos.count << 2 | (dst ? 1 : 0)))
            for (start, type, payload) in packets {
                let word = (start ? 0x8000 : 0) | (type << 11) | payload.count
                sector.append(contentsOf: be16(word))
            }
            for tc in frameInfos {
                sector.append(contentsOf: [UInt8(tc.minutes), UInt8(tc.seconds), UInt8(tc.frames)])
                if dst { sector.append(8) }
            }
            for (_, _, payload) in packets { sector.append(payload) }
            precondition(sector.count == S)
            audio.append(sector)
            consumed += take
        }
        let audioStart = 560
        let audioSectors = audio.count / S

        // --- layout: 510 master, 511 text, 544 area toc (8 sectors), 560... audio ---
        image = Data(count: audioStart * S)
        // Master TOC
        var m = Data(count: S)
        put(&m, Array("SACDMTOC".utf8), at: 0); put(&m, [1, 0x14], at: 8)
        put(&m, be16(1), at: 16); put(&m, be16(1), at: 18)
        put(&m, be32(544), at: 64)
        put(&m, Array("FAKE-001".utf8), at: 88)
        put(&m, be16(1999), at: 120); put(&m, [3, 14], at: 122)
        put(&m, Array("en".utf8), at: 136); put(&m, [1], at: 138)
        put(&m, [1, 0, 0, 23], at: 104)        // disc genre: category 1, "Rock Music"
        image.replaceSubrange((510 * S)..<(511 * S), with: m)
        // Master text
        var t = Data(count: S)
        put(&t, Array("SACDText".utf8), at: 0)
        put(&t, be16(100), at: 16); put(&t, be16(140), at: 18)
        put(&t, Array(title.utf8) + [0], at: 100); put(&t, Array(artist.utf8) + [0], at: 140)
        image.replaceSubrange((511 * S)..<(512 * S), with: t)
        // Area TOC
        var a = Data(count: S)
        put(&a, Array((channels > 2 ? "MULCHTOC" : "TWOCHTOC").utf8), at: 0); put(&a, [1, 0x14], at: 8)
        put(&a, be16(8), at: 10)
        put(&a, [4], at: 20); put(&a, [dst ? 0 : 2], at: 21)
        put(&a, [UInt8(channels)], at: 32)
        let play = SACDTime(totalFrames: totalFrames)
        put(&a, [UInt8(play.minutes), UInt8(play.seconds), UInt8(play.frames)], at: 64)
        put(&a, [0, UInt8(tracks.count)], at: 68)
        put(&a, be32(audioStart), at: 72); put(&a, be32(audioStart + audioSectors - 1), at: 76)
        put(&a, Array("en".utf8), at: 88); put(&a, [1], at: 90)
        image.replaceSubrange((544 * S)..<(545 * S), with: a)
        // TRL1 (sectors) and TRL2 (times)
        var trl1 = Data(count: S), trl2 = Data(count: S)
        put(&trl1, Array("SACDTRL1".utf8), at: 0); put(&trl2, Array("SACDTRL2".utf8), at: 0)
        for (k, tr) in tracks.enumerated() {
            let startSector = audioStart + tr.startFrame * frameBytes / audioPerSector
            put(&trl1, be32(startSector), at: 8 + 4 * k)
            put(&trl1, be32(tr.durationFrames * frameBytes / audioPerSector), at: 8 + 1020 + 4 * k)
            let st = SACDTime(totalFrames: tr.startFrame), du = SACDTime(totalFrames: tr.durationFrames)
            put(&trl2, [UInt8(st.minutes), UInt8(st.seconds), UInt8(st.frames), 0], at: 8 + 4 * k)
            put(&trl2, [UInt8(du.minutes), UInt8(du.seconds), UInt8(du.frames), 0], at: 8 + 1020 + 4 * k)
        }
        image.replaceSubrange((545 * S)..<(546 * S), with: trl1)
        image.replaceSubrange((546 * S)..<(547 * S), with: trl2)
        // IGL: ISRCs then genres (spans 2 sectors)
        var igl = Data(count: 2 * S)
        put(&igl, Array("SACD_IGL".utf8), at: 0)
        for (k, tr) in tracks.enumerated() {
            if let isrc = tr.isrc { put(&igl, Array(isrc.utf8), at: 8 + 12 * k) }
            put(&igl, [1, 0, 0, 14], at: 8 + 3060 + 4 * k)       // Jazz
        }
        image.replaceSubrange((547 * S)..<(549 * S), with: igl)
        // Track text (2 sectors)
        var txt = Data(count: 2 * S)
        put(&txt, Array("SACDTTxt".utf8), at: 0)
        var pos = 600
        for (k, tr) in tracks.enumerated() {
            put(&txt, be16(pos), at: 8 + 2 * k)
            var items: [(Int, String)] = [(1, tr.title)]
            if let p = tr.performer { items.append((2, p)) }
            put(&txt, [UInt8(items.count), 0, 0, 0], at: pos)
            var p = pos + 4
            for (type, text) in items {
                put(&txt, [UInt8(type), 0x20] + Array(text.utf8) + [0], at: p)
                p += 2 + text.utf8.count + 1
                p = (p + 3) & ~3
            }
            pos = p
        }
        image.replaceSubrange((549 * S)..<(551 * S), with: txt)
        image.append(audio)
        try image.write(to: url)
    }
}

enum Samples {
    static let root = URL(fileURLWithPath: NSString(string: "~/mactagger-samples").expandingTildeInPath)
    static var loveSupremeISO: URL? {
        let u = root.appending(path: "isos/A Love Supreme.iso")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
    static var goldbergISO: URL? {
        let u = root.appending(path: "isos/J.S.BACH_GOLDBERG VARIATIONS,BWV.988.iso")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
    static var spaceOddityISO: URL? {
        let u = root.appending(path: "isos/David Bowie - Space Oddity.iso")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
    static var loveSupremeDSFs: [URL] {
        let dir = root.appending(path: "dsf/A Love Supreme")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter { $0.hasSuffix(".dsf") && !$0.hasPrefix("._") }.sorted().map { dir.appending(path: $0) }
    }
    static func temp(_ name: String) throws -> URL {
        let u = FileManager.default.temporaryDirectory.appending(path: "sacdkit-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}

@Suite("Scarletbook synthetic")
struct SyntheticTests {

    static func makeDisc(dst: Bool = false) -> FakeDisc {
        FakeDisc(
            channels: 2,
            tracks: [
                FakeDisc.Track(startFrame: 150, durationFrames: 200, title: "First Song", performer: "Someone", isrc: "USABC0100001"),
                FakeDisc.Track(startFrame: 375, durationFrames: 150, title: "Second / Song", performer: nil, isrc: nil),
                FakeDisc.Track(startFrame: 525, durationFrames: 75, title: "Third", performer: "Guest", isrc: "USABC0100003"),
            ],
            totalFrames: 600,
            leadInFrames: 150,
            dst: dst
        )
    }

    @Test func readsAreaTracksTextsAndCodes() throws {
        let dir = try Samples.temp("read")
        defer { try? FileManager.default.removeItem(at: dir) }
        let iso = dir.appending(path: "fake.iso")
        try Self.makeDisc().write(to: iso)

        let disc = try SACDDiscReader.read(url: iso)
        #expect(disc.title == "Fake Album")
        #expect(disc.artist == "Fake Artist")
        #expect(disc.year == "1999")
        #expect(disc.areas.count == 1)
        let area = try #require(disc.stereoArea)
        #expect(area.channelCount == 2)
        #expect(!area.isDST)
        #expect(area.tracks.count == 3)
        #expect(area.playTime.totalFrames == 600)
        let t1 = area.tracks[0], t2 = area.tracks[1], t3 = area.tracks[2]
        #expect(t1.title == "First Song")
        #expect(t1.performer == "Someone")
        #expect(t1.isrc == "USABC0100001")
        #expect(t1.genre == "Jazz")
        #expect(t1.startTime.totalFrames == 150)
        #expect(t1.duration.totalFrames == 200)
        #expect(t2.title == "Second / Song")
        #expect(t2.performer == nil)
        #expect(t2.isrc == nil)
        #expect(t3.title == "Third")
        #expect(t3.performer == "Guest")
        #expect(area.audioStartSector == 560)
    }

    @Test func frameReaderReassemblesEveryFrame() throws {
        let dir = try Samples.temp("frames")
        defer { try? FileManager.default.removeItem(at: dir) }
        let iso = dir.appending(path: "fake.iso")
        let fake = Self.makeDisc()
        try fake.write(to: iso)
        let disc = try SACDDiscReader.read(url: iso)
        let area = try #require(disc.stereoArea)

        let reader = try SACDFrameReader(url: iso, firstSector: area.audioStartSector, lastSector: area.audioEndSector)
        var count = 0
        while let frame = try reader.next() {
            #expect(frame.timecode.totalFrames == count)
            #expect(frame.data.count == fake.frameBytes)
            #expect(frame.data == FakeDisc.frameData(index: count, bytes: fake.frameBytes))
            count += 1
        }
        #expect(count == 600)
    }

    @Test func extractsTracksWithPauseAppendedAndTags() throws {
        let dir = try Samples.temp("extract")
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = try Samples.temp("out")
        defer { try? FileManager.default.removeItem(at: out) }
        let iso = dir.appending(path: "fake.iso")
        let fake = Self.makeDisc()
        try fake.write(to: iso)
        let disc = try SACDDiscReader.read(url: iso)
        let area = try #require(disc.stereoArea)

        let outcome = try SACDExtractor().extract(disc: disc, area: area, destinationRoot: out)
        #expect(outcome.verified, "warnings \(outcome.warnings)")
        #expect(outcome.outputFolder.path.hasSuffix("Fake Artist/Fake Album (1999)"))
        #expect(outcome.droppedLeadInFrames == 150)
        #expect(outcome.droppedPauseFrames == 0)
        #expect(outcome.tracks.map(\.frames) == [225, 150, 75])     // 25-frame pause joins track 1
        #expect(outcome.tracks.map { $0.url.lastPathComponent } == ["01 First Song.dsf", "02 Second - Song.dsf", "03 Third.dsf"])
        #expect(outcome.tracks[0].sampleCount == UInt64(225) * 37632)

        // DSF audio equals de-interleaved, bit-reversed frames.
        let dsf = try DSFFile(source: FileHandleDataSource(url: outcome.tracks[1].url))
        #expect(dsf.channelCount == 2)
        #expect(dsf.sampleRate == 2_822_400)
        #expect(dsf.sampleCount == UInt64(150) * 37632)
        let bytes = try Data(contentsOf: outcome.tracks[1].url)
        let firstBlockL = bytes[92..<(92 + 4096)]
        let firstBlockR = bytes[(92 + 4096)..<(92 + 8192)]
        let frame375 = FakeDisc.frameData(index: 375, bytes: fake.frameBytes)
        var expectedL: [UInt8] = [], expectedR: [UInt8] = []
        var i = 0
        while expectedL.count < 4096 {
            expectedL.append(DSFWriter.bitReverse[Int(frame375[i])])
            expectedR.append(DSFWriter.bitReverse[Int(frame375[i + 1])])
            i += 2
        }
        #expect(Array(firstBlockL) == expectedL)
        #expect(Array(firstBlockR) == expectedR)

        // Tags via ID3 → Vorbis bridge.
        let tag = try #require(dsf.id3Tag)
        let v = ID3v2Bridge.toVorbis(tag)
        #expect(v["TITLE"] == ["Second / Song"])
        #expect(v["ARTIST"] == ["Fake Artist"])         // no performer: falls back to disc artist
        #expect(v["ALBUM"] == ["Fake Album"])
        #expect(v["ALBUMARTIST"] == ["Fake Artist"])
        #expect(v["TRACKNUMBER"] == ["2"])
        #expect(v["TRACKTOTAL"] == ["3"])
        #expect(v["DATE"] == ["1999"])
        #expect(v["GENRE"] == ["Jazz"])
        #expect(v["CATALOGNUMBER"] == ["FAKE-001"])
        let first = try DSFFile(source: FileHandleDataSource(url: outcome.tracks[0].url))
        let v1 = ID3v2Bridge.toVorbis(try #require(first.id3Tag))
        #expect(v1["ARTIST"] == ["Someone"])
        #expect(v1["ISRC"] == ["USABC0100001"])

        // Drop policy matches TOC durations.
        var drop = SACDExtractOptions()
        drop.pausePolicy = .drop
        drop.overwriteExisting = true
        let dropped = try SACDExtractor().extract(disc: disc, area: area, destinationRoot: out, options: drop)
        #expect(dropped.verified)
        #expect(dropped.tracks.map(\.frames) == [200, 150, 75])
        #expect(dropped.droppedPauseFrames == 25)

        // Refuses to overwrite by default.
        #expect(throws: SACDExtractError.self) {
            try SACDExtractor().extract(disc: disc, area: area, destinationRoot: out)
        }
    }

    @Test func dstAreaIsRefusedForNow() throws {
        let dir = try Samples.temp("dst")
        defer { try? FileManager.default.removeItem(at: dir) }
        let iso = dir.appending(path: "fake.iso")
        try Self.makeDisc(dst: true).write(to: iso)
        let disc = try SACDDiscReader.read(url: iso)
        let area = try #require(disc.stereoArea)
        #expect(area.isDST)
        // Frames still parse (4-byte frame infos).
        let reader = try SACDFrameReader(url: iso, firstSector: area.audioStartSector, lastSector: area.audioEndSector)
        var n = 0
        while let f = try reader.next() { #expect(f.timecode.totalFrames == n); n += 1 }
        #expect(n == 600)
        #expect(throws: SACDExtractError.dstNotSupported) {
            try SACDExtractor().extract(disc: disc, area: area, destinationRoot: dir)
        }
    }

    @Test func dsfWriterPadsAndReportsSizes() throws {
        let dir = try Samples.temp("dsf")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "t.dsf")
        let w = try DSFWriter(url: url, channelCount: 2)
        try w.write(interleavedFrame: Data([0x01, 0x80, 0xFF, 0x00]))
        let (samples, size) = try w.finish(id3: Data([0x49, 0x44, 0x33, 3, 0, 0, 0, 0, 0, 0]))
        #expect(samples == 16)
        #expect(size == 92 + 8192 + 10)
        let bytes = try Data(contentsOf: url)
        #expect(bytes[92] == 0x80)          // 0x01 reversed
        #expect(bytes[93] == 0xFF)
        #expect(bytes[92 + 4096] == 0x01)   // 0x80 reversed
        #expect(bytes[92 + 4097] == 0x00)
        let dsf = try DSFFile(source: FileHandleDataSource(url: url))
        #expect(dsf.sampleCount == 16)
        #expect(dsf.blockSizePerChannel == 4096)
    }
}

@Suite("Real images", .serialized)
struct RealImageTests {

    @Test func parsesLoveSupreme() throws {
        guard let iso = Samples.loveSupremeISO else { return }
        let disc = try SACDDiscReader.read(url: iso)
        #expect(disc.title == "A Love Supreme")
        #expect(disc.artist == "John Coltrane")
        #expect(disc.info.discCatalogNumber == "CIPJ 77 SA")
        let area = try #require(disc.stereoArea)
        #expect(area.tracks.count == 3)
        #expect(area.tracks[0].title == "A Love Supreme, Part One: \"Acknowledgement\"")
        #expect(area.tracks[0].performer == "John Coltrane")
        #expect(area.tracks[0].startTime.description == "00:02:00")
        #expect(area.tracks[0].duration.description == "07:44:10")
        #expect(area.tracks[1].startTime.description == "07:48:22")
        #expect(area.tracks[2].title?.hasPrefix("A Love Supreme, Part Three") == true)
        #expect(area.tracks[0].startSector == 1324)
        #expect(area.tracks[1].startSector == 164526)
        #expect(area.tracks[0].isrc == nil)
    }

    @Test func parsesGoldbergTitlesAndISRCs() throws {
        guard let iso = Samples.goldbergISO else { return }
        let disc = try SACDDiscReader.read(url: iso)
        let area = try #require(disc.stereoArea)
        #expect(area.tracks.count == 32)
        #expect(area.tracks[0].title == "BACH:Goldberg Variations Theme:Aria")
        #expect(area.tracks[1].title == "BACH:Goldberg Variations Variation 1")
        #expect(area.tracks[0].isrc == "USSM18100503")
        #expect(area.tracks[31].isrc == "USSM18100534")
    }

    @Test func parsesDSTDisc() throws {
        guard let iso = Samples.spaceOddityISO else { return }
        let disc = try SACDDiscReader.read(url: iso)
        let area = try #require(disc.stereoArea)
        #expect(area.isDST)
        #expect(area.tracks.count == 9)
        #expect(area.tracks[1].startTime.description == "05:16:28")
        #expect(area.tracks[0].startSector == 584)
        // The frame reader copes with DST sectors (4-byte frame infos).
        let reader = try SACDFrameReader(url: iso, firstSector: area.audioStartSector, lastSector: min(area.audioStartSector + 200, area.audioEndSector))
        var n = 0
        var last = -1
        while let f = try reader.next() {
            #expect(f.timecode.totalFrames == last + 1)
            last = f.timecode.totalFrames
            n += 1
        }
        #expect(n > 100)
    }

    // Throughput check on the real disc (1.4 GB). DRTAGGER_SLOW_TESTS=1.
    @Test func realExtractionThroughput() throws {
        guard ProcessInfo.processInfo.environment["DRTAGGER_SLOW_TESTS"] == "1",
              let iso = Samples.loveSupremeISO else { return }
        let out = try Samples.temp("speed")
        defer { try? FileManager.default.removeItem(at: out) }
        let disc = try SACDDiscReader.read(url: iso)
        let area = try #require(disc.stereoArea)
        let started = Date()
        let reader = try SACDFrameReader(url: iso, firstSector: area.audioStartSector, lastSector: area.audioEndSector)
        var frames = 0
        while try reader.next() != nil { frames += 1 }
        let readSeconds = Date().timeIntervalSince(started)
        let outcome = try SACDExtractor().extract(disc: disc, area: area, destinationRoot: out)
        let isoBytes = Double(reader.totalSectors) * Double(Scarletbook.sectorSize)
        print(String(format: "SACD read only: %d frames in %.1f s (%.0f MB/s); extract: %.1f s (%.0f MB/s)",
                     frames, readSeconds, isoBytes / readSeconds / 1e6, outcome.elapsedSeconds, isoBytes / outcome.elapsedSeconds / 1e6))
        #expect(outcome.verified)
        #expect(outcome.elapsedSeconds < 60, "extraction slower than 60 s")
    }

    // Extracts the real disc with the sacd_extract policy and compares every
    // DSF's audio with sacd_extract's own output. DRTAGGER_SLOW_TESTS=1.
    @Test func extractionMatchesSACDExtractByteForByte() throws {
        guard ProcessInfo.processInfo.environment["DRTAGGER_SLOW_TESTS"] == "1",
              let iso = Samples.loveSupremeISO else { return }
        let reference = Samples.loveSupremeDSFs
        guard reference.count == 3 else { return }
        let out = try Samples.temp("als")
        defer { try? FileManager.default.removeItem(at: out) }

        let disc = try SACDDiscReader.read(url: iso)
        let area = try #require(disc.stereoArea)
        var options = SACDExtractOptions()
        options.pausePolicy = .drop
        let outcome = try SACDExtractor().extract(disc: disc, area: area, destinationRoot: out, options: options)
        #expect(outcome.verified, "warnings \(outcome.warnings)")
        #expect(outcome.tracks.count == 3)

        for (mine, theirs) in zip(outcome.tracks, reference) {
            let a = try DSFFile(source: FileHandleDataSource(url: mine.url))
            let b = try DSFFile(source: FileHandleDataSource(url: theirs))
            #expect(a.sampleCount == b.sampleCount, "\(mine.url.lastPathComponent) vs \(theirs.lastPathComponent)")
            #expect(a.channelCount == b.channelCount)
            // Compare audio bytes in 4 MiB chunks.
            let fa = try FileHandle(forReadingFrom: mine.url), fb = try FileHandle(forReadingFrom: theirs)
            defer { try? fa.close(); try? fb.close() }
            try fa.seek(toOffset: a.dataChunkOffset + 12)
            try fb.seek(toOffset: b.dataChunkOffset + 12)
            var remaining = Int(min(a.dataChunkSize, b.dataChunkSize)) - 12
            var offset = 0
            var equal = true
            while remaining > 0 && equal {
                let n = min(4 << 20, remaining)
                let x = try fa.read(upToCount: n) ?? Data()
                let y = try fb.read(upToCount: n) ?? Data()
                if x != y { equal = false }
                remaining -= n
                offset += n
            }
            #expect(equal, "audio differs in \(mine.url.lastPathComponent) near byte \(offset)")
        }
    }
}
