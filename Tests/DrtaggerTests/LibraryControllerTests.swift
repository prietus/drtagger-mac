import Foundation
import LibraryKit
import SwiftData
import TagKit
import Testing
@testable import drtagger

@Suite("LibraryController")
@MainActor
struct LibraryControllerTests {

    private func makeController() throws -> LibraryController {
        let schema = Schema([AlbumRecord.self])
        let config = ModelConfiguration("Tests", schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return LibraryController(container: container)
    }

    private func makeLibrary() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "drtagger-lib-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fm = FileManager.default
        try fm.createDirectory(at: root.appending(path: "Artist - First (1999)"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appending(path: "Second/CD1"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appending(path: "Second/CD2"), withIntermediateDirectories: true)
        for name in ["Artist - First (1999)/01.flac", "Artist - First (1999)/02.flac",
                     "Second/CD1/01.dsf", "Second/CD2/01.dsf", "Second/CD2/02.dsf"] {
            try Data(count: 4).write(to: root.appending(path: name))
        }
        return root
    }

    @Test func siblingDiscFoldersBecomeAReleaseSet() async throws {
        let controller = try makeController()
        let root = FileManager.default.temporaryDirectory.appending(path: "drtagger-set-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        for (folder, count) in [("Box/Led Zeppelin - Box Set (Disc 1)", 1), ("Box/Led Zeppelin - Box Set (Disc 2)", 2), ("Box/Something Else", 1)] {
            try fm.createDirectory(at: root.appending(path: folder), withIntermediateDirectories: true)
            for n in 1...count { try Data(count: 4).write(to: root.appending(path: "\(folder)/0\(n).flac")) }
        }
        await controller.addRoots([root])
        let records = controller.allRecords()
        #expect(records.count == 3)
        let disc1 = try #require(records.first { $0.path.hasSuffix("(Disc 1)") })
        let disc2 = try #require(records.first { $0.path.hasSuffix("(Disc 2)") })
        let other = try #require(records.first { $0.path.hasSuffix("Something Else") })
        #expect(disc1.setID != nil && disc1.setID == disc2.setID, "siblings with disc numbers are one set")
        #expect(disc1.setPosition == 1 && disc2.setPosition == 2 && disc2.setTotal == 2)
        #expect(disc1.setTitle == "Led Zeppelin - Box Set")
        #expect(other.setID == nil)
        #expect(controller.members(of: disc2).map(\.path) == [disc1.path, disc2.path])
        #expect(controller.isLeader(disc1) && !controller.isLeader(disc2))
        #expect(disc2.discPosition == 2)

        controller.setPosition(disc2, to: 3)
        #expect(disc1.setTotal == 3)
        controller.ungroup(disc1)
        #expect(disc1.setID == nil && disc2.setID == nil)
        #expect(controller.siblingCandidates(of: disc1).map(\.path) == [disc2.path], "regroupable by hand")
        controller.group([disc1, disc2])
        #expect(disc1.setID != nil && disc2.setPosition == 2)

        // A disc added in a later scan joins the existing set.
        try fm.createDirectory(at: root.appending(path: "Box/Led Zeppelin - Box Set (Disc 3)"), withIntermediateDirectories: true)
        try Data(count: 4).write(to: root.appending(path: "Box/Led Zeppelin - Box Set (Disc 3)/01.flac"))
        await controller.addRoots([root.appending(path: "Box/Led Zeppelin - Box Set (Disc 3)")])
        let disc3 = try #require(controller.allRecords().first { $0.path.hasSuffix("(Disc 3)") })
        #expect(disc3.setID == disc1.setID && disc3.setPosition == 3 && disc1.setTotal == 3)

        // A lone disc that formed a set of one is regrouped when its sibling arrives.
        let loneRoot = root.appending(path: "Lone")
        try fm.createDirectory(at: loneRoot.appending(path: "Opera - Disc 1 of 2"), withIntermediateDirectories: true)
        try Data(count: 4).write(to: loneRoot.appending(path: "Opera - Disc 1 of 2/01.flac"))
        await controller.addRoots([loneRoot.appending(path: "Opera - Disc 1 of 2")])
        let lone = try #require(controller.allRecords().first { $0.path.hasSuffix("Disc 1 of 2") })
        #expect(lone.setID != nil && controller.members(of: lone).count == 1)
        try fm.createDirectory(at: loneRoot.appending(path: "Opera - Disc 2 of 2"), withIntermediateDirectories: true)
        try Data(count: 4).write(to: loneRoot.appending(path: "Opera - Disc 2 of 2/01.flac"))
        await controller.addRoots([loneRoot.appending(path: "Opera - Disc 2 of 2")])
        #expect(controller.members(of: lone).count == 2)
    }

    @Test func foldersTaggedWithOneReleaseBecomeASet() async throws {
        let controller = try makeController()
        let root = FileManager.default.temporaryDirectory.appending(path: "drtagger-tagged-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        func wav() -> Data {
            var d = Data("RIFF".utf8); var n = UInt32(36 + 400).littleEndian; d.append(Data(bytes: &n, count: 4)); d.append(Data("WAVEfmt ".utf8))
            var fmt: [UInt8] = [16,0,0,0, 1,0, 2,0, 0x44,0xAC,0,0, 0x10,0xB1,2,0, 4,0, 16,0]; d.append(Data(fmt)); fmt.removeAll()
            d.append(Data("data".utf8)); var m = UInt32(400).littleEndian; d.append(Data(bytes: &m, count: 4)); d.append(Data(count: 400)); return d
        }
        func album(_ folder: String, mbid: String) throws {
            try fm.createDirectory(at: root.appending(path: folder), withIntermediateDirectories: true)
            let url = root.appending(path: "\(folder)/01.wav")
            try wav().write(to: url)
            var t = TagSet(); t.set(TagField.mbAlbumID, mbid)
            try TaggedFile.write(url, tags: t)
        }
        for n in [2, 3, 4] { try album("Piano Sonatas Vol.\(n)", mbid: "box-0001") }
        try album("Kind of Blue", mbid: "kob-1")
        try album("Kind of Blue copy", mbid: "kob-1")
        await controller.addRoots([root])
        let records = controller.allRecords()
        let vols = records.filter { $0.displayTitle.contains("Vol") }.sorted { ($0.setPosition ?? 0) < ($1.setPosition ?? 0) }
        #expect(vols.count == 3 && Set(vols.compactMap(\.setID)).count == 1, "same release, numbered folders: one set")
        #expect(vols.map(\.setPosition) == [2, 3, 4])
        #expect(records.filter { $0.displayTitle.hasPrefix("Kind of Blue") }.allSatisfy { $0.setID == nil }, "two copies are not a set")
    }

    @Test func addRootsStoresEveryDetectedAlbum() async throws {
        let controller = try makeController()
        let root = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        await controller.addRoots([root])

        let records = controller.allRecords()
        #expect(records.count == 2)
        #expect(records.allSatisfy { $0.state == .scanned })
        let first = try #require(records.first { $0.displayTitle == "First" })
        #expect(first.artistHint == "Artist")
        #expect(first.yearHint == "1999")
        #expect(first.trackCount == 2)
        #expect(first.kind == .trackFolder)
        #expect(first.formats == [.flac])
        #expect(first.detected?.discs.count == 1)

        let second = try #require(records.first { $0.displayTitle == "Second" })
        #expect(second.discCount == 2)
        #expect(second.trackCount == 3)
        #expect(second.subtitle.contains("3 tracks"))
        #expect(second.subtitle.contains("2 discs"))

        #expect(controller.selection != nil)
        #expect(controller.lastScanSummary?.contains("2 added") == true)
        #expect(!controller.isScanning)
    }

    @Test func rescanningUpdatesInsteadOfDuplicating() async throws {
        let controller = try makeController()
        let root = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        await controller.addRoots([root])
        let first = try #require(controller.allRecords().first { $0.displayTitle == "First" })
        first.state = .needsReview

        // Add a track, rescan the single album.
        try Data(count: 4).write(to: root.appending(path: "Artist - First (1999)/03.flac"))
        await controller.rescan(first)

        #expect(controller.allRecords().count == 2)
        #expect(first.trackCount == 3)
        #expect(first.state == .needsReview, "rescan keeps a state beyond scanned")
        #expect(controller.lastScanSummary?.contains("1 updated") == true)
    }

    @Test func rescanOfVanishedAlbumFlagsError() async throws {
        let controller = try makeController()
        let root = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        await controller.addRoots([root])
        let first = try #require(controller.allRecords().first { $0.displayTitle == "First" })
        try FileManager.default.removeItem(at: first.url)

        await controller.rescan(first)
        #expect(first.state == .error)
        #expect(first.errorMessage != nil)
    }

    @Test func removeDeletesRecordsAndClearsSelection() async throws {
        let controller = try makeController()
        let root = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        await controller.addRoots([root])
        let records = controller.allRecords()
        let selected = try #require(controller.record(id: controller.selection))
        controller.remove([selected])
        #expect(controller.selection == nil)
        #expect(controller.allRecords().count == records.count - 1)

        controller.removeAll()
        #expect(controller.allRecords().isEmpty)
    }

    @Test func addingNothingOrMissingPathsIsHarmless() async throws {
        let controller = try makeController()
        await controller.addRoots([])
        await controller.addRoots([URL(fileURLWithPath: "/nonexistent/path/\(UUID().uuidString)")])
        #expect(controller.allRecords().isEmpty)
        #expect(controller.sessionIssues.count == 1)
    }
}
