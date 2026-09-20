import Foundation
import Testing
@testable import drtagger

@Suite("AlbumQueue")
@MainActor
struct AlbumQueueTests {

    private func makeTempDir(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "drtagger-tests-\(UUID().uuidString)-\(name)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func addsFoldersAndSelectsFirst() throws {
        let queue = AlbumQueue()
        let a = try makeTempDir("a")
        let b = try makeTempDir("b")
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }

        let added = queue.add(urls: [a, b])
        #expect(added.count == 2)
        #expect(queue.albums.count == 2)
        #expect(queue.selection == added.first?.id)
        #expect(queue.albums.allSatisfy { $0.state == .pending })
    }

    @Test func ignoresDuplicatesAndMissingPaths() throws {
        let queue = AlbumQueue()
        let a = try makeTempDir("a")
        defer { try? FileManager.default.removeItem(at: a) }
        let missing = a.appending(path: "does-not-exist")

        queue.add(urls: [a])
        let second = queue.add(urls: [a, missing, a.appending(path: ".")])
        #expect(second.isEmpty)
        #expect(queue.albums.count == 1)
    }

    @Test func acceptsStandaloneImageFilesOnly() throws {
        let dir = try makeTempDir("files")
        defer { try? FileManager.default.removeItem(at: dir) }
        let iso = dir.appending(path: "disc.iso")
        let txt = dir.appending(path: "notes.txt")
        try Data().write(to: iso)
        try Data().write(to: txt)

        #expect(AlbumQueue.isAcceptable(iso))
        #expect(!AlbumQueue.isAcceptable(txt))
    }

    @Test func removingSelectedEntryMovesSelection() throws {
        let queue = AlbumQueue()
        let a = try makeTempDir("a")
        let b = try makeTempDir("b")
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }

        let added = queue.add(urls: [a, b])
        queue.selection = added[1].id
        queue.remove(ids: [added[1].id])
        #expect(queue.albums.count == 1)
        #expect(queue.selection == added[0].id)
    }
}
