import Foundation
import Testing
@testable import LibraryKit

// Each test builds a throwaway folder tree; audio files are empty stubs
// because the scanner only looks at names, existence and sizes.
struct TempTree {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "libscan-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    @discardableResult
    func dir(_ path: String) throws -> URL {
        let url = root.appending(path: path, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func file(_ path: String, _ contents: String = "", bytes: Int = 0) throws -> URL {
        let url = root.appending(path: path, directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if bytes > 0 {
            try Data(count: bytes).write(to: url)
        } else {
            try Data(contents.utf8).write(to: url)
        }
        return url
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("LibraryScanner")
struct LibraryScannerTests {

    static func cue(image: String, tracks: Int = 3) -> String {
        var s = "PERFORMER \"Artist\"\nTITLE \"Album\"\nFILE \"\(image)\" WAVE\n"
        for n in 1...tracks {
            s += "  TRACK \(String(format: "%02d", n)) AUDIO\n    TITLE \"Track \(n)\"\n    INDEX 01 \(String(format: "%02d", (n - 1) * 3)):00:00\n"
        }
        return s
    }

    @Test func trackFolderWithArtwork() throws {
        let t = try TempTree()
        defer { t.cleanup() }
        let album = try t.dir("Artist - Album (2001)")
        try t.file("Artist - Album (2001)/01 - One.flac", bytes: 10)
        try t.file("Artist - Album (2001)/10 - Ten.flac", bytes: 10)
        try t.file("Artist - Album (2001)/02 - Two.flac", bytes: 10)
        try t.file("Artist - Album (2001)/folder.jpg")
        try t.file("Artist - Album (2001)/Scans/back.png")
        try t.file("Artist - Album (2001)/._01 - One.flac")
        try t.file("Artist - Album (2001)/rip.log")

        let result = LibraryScanner().scan([t.root])
        #expect(result.albums.count == 1)
        let a = try #require(result.albums.first)
        #expect(a.kind == .trackFolder)
        #expect(a.url.standardizedFileURL == album.standardizedFileURL)
        #expect(a.discs.count == 1)
        #expect(a.discs[0].trackFiles.map(\.fileName) == ["01 - One.flac", "02 - Two.flac", "10 - Ten.flac"])
        #expect(a.artworkFiles.map(\.lastPathComponent) == ["folder.jpg", "back.png"])
        #expect(a.discs[0].logFiles.count == 1)
        #expect(a.titleHint == "Album")
        #expect(a.artistHint == "Artist")
        #expect(a.yearHint == "2001")
        #expect(a.formats == [.flac])
        #expect(result.issues.isEmpty)
    }

    @Test func cueImageAlbum() throws {
        let t = try TempTree()
        defer { t.cleanup() }
        try t.dir("Album")
        try t.file("Album/Album.ape", bytes: 100)
        try t.file("Album/Album.cue", Self.cue(image: "Album.ape", tracks: 4))

        let result = LibraryScanner().scan([t.root])
        let a = try #require(result.albums.first)
        #expect(result.albums.count == 1)
        #expect(a.kind == .cueImage)
        #expect(a.discs[0].imageFile?.format == .ape)
        #expect(a.discs[0].imageFile?.fileSize == 100)
        #expect(a.discs[0].cue?.audioTracks.count == 4)
        #expect(a.trackCount == 4)
        #expect(a.titleHint == "Album")
        #expect(a.artistHint == "Artist")
    }

    @Test func cueWithBinImage() throws {
        let t = try TempTree()
        defer { t.cleanup() }
        try t.file("Rip/disc.bin", bytes: 50)
        try t.file("Rip/disc.cue", "FILE \"disc.bin\" BINARY\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n")

        let result = LibraryScanner().scan([t.root])
        let a = try #require(result.albums.first)
        #expect(a.kind == .cueImage)
        #expect(a.discs[0].imageFile?.fileName == "disc.bin")
    }

    @Test func cueMultiFileAlbum() throws {
        let t = try TempTree()
        defer { t.cleanup() }
        try t.file("Ella/01 - Mean to Me.wav", bytes: 5)
        try t.file("Ella/02 - How Long.wav", bytes: 5)
        try t.file("Ella/Ella.cue", """
        FILE "01 - Mean to Me.wav" WAVE
          TRACK 01 AUDIO
            INDEX 01 00:00:00
        FILE "02 - How Long.wav" WAVE
          TRACK 02 AUDIO
            INDEX 01 00:00:00
        """)

        let result = LibraryScanner().scan([t.root])
        let a = try #require(result.albums.first)
        #expect(result.albums.count == 1)
        #expect(a.kind == .cueMultiFile)
        #expect(a.discs[0].trackFiles.count == 2)
        #expect(a.trackCount == 2)
    }

    @Test func orphanCueBecomesHintForSplitTracks() throws {
        let t = try TempTree()
        defer { t.cleanup() }
        try t.file("Split/01 - A.flac", bytes: 5)
        try t.file("Split/02 - B.flac", bytes: 5)
        try t.file("Split/Split.cue", Self.cue(image: "Split.ape", tracks: 2))

        let result = LibraryScanner().scan([t.root])
        let a = try #require(result.albums.first)
        #expect(result.albums.count == 1)
        #expect(a.kind == .trackFolder)
        #expect(a.discs[0].cue?.title == "Album")
        #expect(a.discs[0].trackFiles.count == 2)
        #expect(result.issues.count == 1)
        #expect(result.issues[0].message.contains("missing"))
    }

    @Test func multiDiscFolders() throws {
        let t = try TempTree()
        defer { t.cleanup() }
        try t.dir("Box")
        try t.file("Box/CD1/01.flac", bytes: 1)
        try t.file("Box/CD1/02.flac", bytes: 1)
        try t.file("Box/Disc 2/01.flac", bytes: 1)
        try t.file("Box/cover.jpg")

        let result = LibraryScanner().scan([t.root])
        #expect(result.albums.count == 1)
        let a = try #require(result.albums.first)
        #expect(a.kind == .trackFolder)
        #expect(a.discs.map(\.number) == [1, 2])
        #expect(a.discs[0].trackFiles.count == 2)
        #expect(a.discs[1].trackFiles.count == 1)
        #expect(a.trackCount == 3)
        #expect(a.artworkFiles.count == 1)
        #expect(a.url.lastPathComponent == "Box")
    }

    @Test func multiDiscWithImagesPerDisc() throws {
        let t = try TempTree()
        defer { t.cleanup() }
        try t.file("Set/Disc 1/d1.flac", bytes: 1)
        try t.file("Set/Disc 1/d1.cue", Self.cue(image: "d1.flac", tracks: 2))
        try t.file("Set/Disc 2/d2.flac", bytes: 1)
        try t.file("Set/Disc 2/d2.cue", Self.cue(image: "d2.flac", tracks: 5))

        let result = LibraryScanner().scan([t.root])
        #expect(result.albums.count == 1)
        let a = try #require(result.albums.first)
        #expect(a.kind == .cueImage)
        #expect(a.discs.count == 2)
        #expect(a.trackCount == 7)
    }

    @Test func nestedLibraryFindsEveryAlbum() throws {
        let t = try TempTree()
        defer { t.cleanup() }
        try t.file("Music/Rock/A/01.flac", bytes: 1)
        try t.file("Music/Rock/B/01.wv", bytes: 1)
        try t.file("Music/Jazz/C/CD1/01.dsf", bytes: 1)
        try t.file("Music/Jazz/C/CD2/01.dsf", bytes: 1)
        try t.file("Music/notes.txt")

        let result = LibraryScanner().scan([t.root])
        let names = result.albums.map { $0.url.lastPathComponent }.sorted()
        #expect(names == ["A", "B", "C"])
        #expect(result.foldersVisited >= 6)
    }

    @Test func sacdISOAlbumAndDataISO() throws {
        let t = try TempTree()
        defer { t.cleanup() }
        try t.dir("ISOs")
        let iso = t.root.appending(path: "ISOs/Album.iso")
        try FakeSACD.write(to: iso)
        try t.file("ISOs/linux.iso", bytes: SACDProbe.sectorSize * 520)
        try t.file("ISOs/Album.xml", "<x/>")
        try t.file("ISOs/front.jpg")

        let result = LibraryScanner().scan([t.root])
        #expect(result.albums.count == 1)
        let a = try #require(result.albums.first)
        #expect(a.kind == .sacdISO)
        #expect(a.url.lastPathComponent == "Album.iso")
        #expect(a.sacd?.trackCount == 3)
        #expect(a.trackCount == 3)
        #expect(a.titleHint == "Disc Title")
        #expect(a.artistHint == "Fake Artist")
        #expect(a.artworkFiles.count == 1)
        #expect(result.issues.contains { $0.url.lastPathComponent == "linux.iso" })
    }

    @Test func singleFilesAsRoots() throws {
        let t = try TempTree()
        defer { t.cleanup() }
        let iso = t.root.appending(path: "Album.iso")
        try FakeSACD.write(to: iso)
        let flac = try t.file("Loose/01.flac", bytes: 1)

        let result = LibraryScanner().scan([iso, flac])
        #expect(result.albums.map(\.kind).sorted { $0.rawValue < $1.rawValue } == [.sacdISO, .trackFolder])
    }

    @Test func duplicateRootsAreCollapsed() throws {
        let t = try TempTree()
        defer { t.cleanup() }
        try t.file("A/01.flac", bytes: 1)
        let result = LibraryScanner().scan([t.root, t.root.appending(path: "A")])
        #expect(result.albums.count == 1)
    }

    @Test func folderNameParsing() {
        let p = FolderNameParser.parse("1974 - Diamond Dogs (1984, W. Germany, RCA PD83889)")
        #expect(p.year == "1974")
        #expect(p.title == "Diamond Dogs")
        #expect(p.artist == nil)

        let q = FolderNameParser.parse("1968. Creedence - Bayou Country (Fantasy FCD 8387-2, Germany)")
        #expect(q.year == "1968")
        #expect(q.artist == "Creedence")
        #expect(q.title == "Bayou Country")

        let r = FolderNameParser.parse("(Japanese_SICP-1700).High_Voltage")
        #expect(r.year == nil)
        #expect(r.title == "High Voltage")
        #expect(r.country == "JP")
        #expect(r.notes == ["Japanese SICP-1700"])

        let m = FolderNameParser.parse("Linkin Park - 2003 - Meteora 20th Anniversary Edition (MQA)")
        #expect(m.artist == "Linkin Park")
        #expect(m.year == "2003")
        #expect(m.title == "Meteora")
        #expect(m.edition == "20th Anniversary Edition")
        #expect(m.displayTitle == "Meteora (20th Anniversary Edition)")
        #expect(m.source == .digital)
        #expect(m.notes == ["MQA"])

        let d = FolderNameParser.parse("1974 - Diamond Dogs (1984, W. Germany, RCA PD83889)")
        #expect(d.editionYear == "1984")
        #expect(d.country == "DE")
        #expect(d.source == nil)

        let k = FolderNameParser.parse("Diana Krall- All For You XRCD Japan")
        #expect(k.artist == "Diana Krall")
        #expect(k.title == "All For You")
        #expect(k.source == .cd)
        #expect(k.country == "JP")

        let w = FolderNameParser.parse("Miles Davis All Stars - Walkin' XRCD")
        #expect(w.title == "Walkin'")
        #expect(w.source == .cd)

        let e = FolderNameParser.parse("Ella Fitzgerald & Oscar Peterson - Ella and Oscar (1975, JVC-XRCD)")
        #expect(e.artist == "Ella Fitzgerald & Oscar Peterson")
        #expect(e.title == "Ella and Oscar")
        #expect(e.year == "1975")
        #expect(e.source == .cd)

        let vh = FolderNameParser.parse("Van Halen - 1984")
        #expect(vh.artist == "Van Halen")
        #expect(vh.title == "1984")
        #expect(vh.year == "1984")

        let aja = FolderNameParser.parse("Steely Dan - Aja 1977")
        #expect(aja.title == "Aja")
        #expect(aja.year == "1977")

        let pf = FolderNameParser.parse("Pink Floyd - The Dark Side of the Moon (2011 Remaster) [24-96]")
        #expect(pf.title == "The Dark Side of the Moon")
        #expect(pf.edition == "2011 Remaster")
        #expect(pf.editionYear == "2011")
        #expect(pf.source == .digital)

        let lp = FolderNameParser.parse("Led Zeppelin - Physical Graffiti (24-96 Vinyl Rip)")
        #expect(lp.source == .vinyl, "the physical medium wins over the bit depth")

        let us = FolderNameParser.parse("Some Band - The Best of Us")
        #expect(us.title == "The Best of Us", "a plain word is never a country code")

        let tag = FolderNameParser.parseAlbumTitle("Meteora (20th Anniversary Edition)")
        #expect(tag.title == "Meteora")
        #expect(tag.edition == "20th Anniversary Edition")
        #expect(FolderNameParser.parseAlbumTitle("Aja").title == "Aja")
        #expect(FolderNameParser.parseAlbumTitle("LP").title == "LP")

        #expect(FileRules.discNumber(fromFolderName: "CD1") == 1)
        #expect(FileRules.discNumber(fromFolderName: "Disc 2 - Live") == 2)
        #expect(FileRules.discNumber(fromFolderName: "disco_3") == 3)
        #expect(FileRules.discNumber(fromFolderName: "Scans") == nil)
        #expect(FileRules.discNumber(fromFolderName: "CD Quality") == nil)
    }

    // Real folders when the local sample copy is present.
    @Test func scansLocalSamplesIfPresent() throws {
        let samples = URL(fileURLWithPath: NSString(string: "~/mactagger-samples").expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: samples.appending(path: "cue").path) else { return }
        let result = LibraryScanner().scan([samples.appending(path: "cue")])
        let byName = Dictionary(uniqueKeysWithValues: result.albums.map { ($0.url.lastPathComponent, $0) })

        let bowie = try #require(byName["1974 - Diamond Dogs (1984, W. Germany, RCA PD83889)"])
        #expect(bowie.kind == .trackFolder)              // image was split; CUE is a hint
        #expect(bowie.discs[0].cue != nil)
        #expect(bowie.discs[0].trackFiles.count == 8)
        #expect(bowie.artworkFiles.count >= 8)           // Folder.jpg/png + Scans/

        let leno = try #require(byName["Leno - Corre, corre (1982)"])
        #expect(leno.kind == .trackFolder)
        #expect(leno.discs[0].cue?.encodingName == "utf-8-bom")
        #expect(leno.discs[0].trackFiles.count == 8)
    }
}

@Suite("VolumeInfo")
struct VolumeInfoTests {
    @Test func rootIsLocalAndMountsAreListed() {
        let mounts = VolumeInfo.mounts()
        #expect(mounts.contains { $0.mountPoint == "/" })
        #expect(VolumeInfo.mount(for: "/")?.mountPoint == "/")
        #expect(!VolumeInfo.isNetworkVolume(URL(fileURLWithPath: NSTemporaryDirectory())))
        #expect(VolumeInfo.mount(for: "/Users")?.isNetwork == false)
    }
}

extension VolumeInfoTests {
    // Automounted NFS shows up as autofs + nfs on the same mount point.
    @Test func prefersRealFileSystemOverAutofs() {
        let nfs = VolumeInfo.mounts().first { $0.isNetwork }
        guard let nfs else { return }     // no network mounts on this machine
        let m = VolumeInfo.mount(for: nfs.mountPoint + "/some/file.iso")
        #expect(m?.fileSystem == nfs.fileSystem)
        #expect(VolumeInfo.isNetworkVolume(URL(fileURLWithPath: nfs.mountPoint + "/x")))
    }
}
