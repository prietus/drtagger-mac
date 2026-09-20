import Foundation
import Testing
@testable import LibraryKit

// Builds a tiny synthetic Scarletbook image: master TOC at sector 510,
// master text at 511, a stereo area TOC at 544 and a multichannel one at 560.
enum FakeSACD {
    static func write(to url: URL, stereoDST: Bool = false, multichannel: Bool = true,
                      title: String = "Fake Album", artist: String = "Fake Artist",
                      charSet: UInt8 = 1) throws {
        let sector = SACDProbe.sectorSize
        var image = Data(count: sector * 600)

        func put(_ bytes: [UInt8], at offset: Int) {
            image.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        }
        func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }

        // Master TOC
        let m = 510 * sector
        put(Array("SACDMTOC".utf8), at: m)
        put([1, 0x14], at: m + 8)
        put(be16(1), at: m + 16)                 // album set size
        put(be16(1), at: m + 18)                 // sequence
        put(Array("ALBCAT-1".utf8), at: m + 24)
        put(be32(544), at: m + 64)               // area 1 TOC
        if multichannel { put(be32(560), at: m + 72) }
        put(Array("CIPJ 77 SA".utf8), at: m + 88)
        put(be16(2010), at: m + 120)
        put([6, 28], at: m + 122)
        put(Array("en".utf8), at: m + 136)
        put([charSet], at: m + 138)

        // Master text: album title at 100, album artist at 140, disc title at 180
        let t = 511 * sector
        put(Array("SACDText".utf8), at: t)
        let encoding: String.Encoding = charSet == 2 ? .isoLatin1 : (charSet == 3 ? .shiftJIS : .utf8)
        let titleBytes = Array(title.data(using: encoding)!)
        let artistBytes = Array(artist.data(using: encoding)!)
        put(be16(100), at: t + 16)
        put(be16(140), at: t + 18)
        put(be16(180), at: t + 32)
        put(titleBytes + [0], at: t + 100)
        put(artistBytes + [0], at: t + 140)
        put(Array("Disc Title".utf8) + [0], at: t + 180)

        // Area TOCs
        func area(at sectorNo: Int, id: String, dst: Bool, channels: UInt8, tracks: UInt8) {
            let a = sectorNo * sector
            put(Array(id.utf8), at: a)
            put([1, 0x14], at: a + 8)
            put([dst ? 0 : 2], at: a + 21)
            put([channels], at: a + 32)
            put([33, 7, 15], at: a + 64)          // 33:07
            put([0, tracks], at: a + 68)
            put(be32(624), at: a + 72)
            put(be32(696144), at: a + 76)
        }
        area(at: 544, id: "TWOCHTOC", dst: stereoDST, channels: 2, tracks: 3)
        if multichannel {
            area(at: 560, id: "MULCHTOC", dst: true, channels: 5, tracks: 3)
        }
        try image.write(to: url)
    }
}

@Suite("SACDProbe")
struct SACDProbeTests {

    private func tempFile(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "sacd-\(UUID().uuidString)-\(name)")
    }

    @Test func recognisesAndDescribesStereoDSDDisc() throws {
        let url = tempFile("dsd.iso")
        defer { try? FileManager.default.removeItem(at: url) }
        try FakeSACD.write(to: url, stereoDST: false, multichannel: false)

        #expect(SACDProbe.isSACD(url: url))
        let info = try SACDProbe.probe(url: url)
        #expect(info.areas.count == 1)
        #expect(info.stereoArea?.frameFormat == .dsd)
        #expect(info.stereoArea?.channelCount == 2)
        #expect(info.stereoArea?.trackCount == 3)
        #expect(info.stereoArea?.playTimeSeconds == 33 * 60 + 7)
        #expect(info.stereoArea?.trackStartSector == 624)
        #expect(info.multichannelArea == nil)
        #expect(!info.hasDST)
        #expect(info.trackCount == 3)
        #expect(info.discCatalogNumber == "CIPJ 77 SA")
        #expect(info.albumCatalogNumber == "ALBCAT-1")
        #expect(info.discDate == "2010-06-28")
        #expect(info.localeLanguage == "en")
        #expect(info.albumTitle == "Fake Album")
        #expect(info.albumArtist == "Fake Artist")
        #expect(info.discTitle == "Disc Title")
        #expect(info.title == "Disc Title")
        #expect(info.artist == "Fake Artist")
    }

    @Test func describesDSTAndMultichannel() throws {
        let url = tempFile("dst.iso")
        defer { try? FileManager.default.removeItem(at: url) }
        try FakeSACD.write(to: url, stereoDST: true, multichannel: true)

        let info = try SACDProbe.probe(url: url)
        #expect(info.areas.count == 2)
        #expect(info.stereoArea?.isDST == true)
        #expect(info.multichannelArea?.channelCount == 5)
        #expect(info.multichannelArea?.isMultichannel == true)
        #expect(info.hasDST)
    }

    @Test func decodesLatin1DiscText() throws {
        let url = tempFile("latin.iso")
        defer { try? FileManager.default.removeItem(at: url) }
        try FakeSACD.write(to: url, title: "Suites für Cello", artist: "János Starker", charSet: 2)

        let info = try SACDProbe.probe(url: url)
        #expect(info.characterSetCode == 2)
        #expect(info.albumTitle == "Suites für Cello")
        #expect(info.albumArtist == "János Starker")
    }

    @Test func rejectsNonSACDFiles() throws {
        let url = tempFile("data.iso")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(count: SACDProbe.sectorSize * 520).write(to: url)
        #expect(!SACDProbe.isSACD(url: url))
        #expect(throws: SACDProbe.ProbeError.notSACD) { try SACDProbe.probe(url: url) }

        let short = tempFile("short.iso")
        defer { try? FileManager.default.removeItem(at: short) }
        try Data(count: 100).write(to: short)
        #expect(!SACDProbe.isSACD(url: short))
    }

    // Runs only when the local sample copy exists.
    @Test func probesRealSampleIfPresent() throws {
        let url = URL(fileURLWithPath: NSString(string: "~/mactagger-samples/isos/A Love Supreme.iso").expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let info = try SACDProbe.probe(url: url)
        #expect(info.title == "A Love Supreme")
        #expect(info.artist == "John Coltrane")
        #expect(info.stereoArea?.frameFormat == .dsd)
        #expect(info.stereoArea?.trackCount == 3)
        #expect(info.discCatalogNumber == "CIPJ 77 SA")
        #expect(info.discDate == "2010-06-28")
    }
}
