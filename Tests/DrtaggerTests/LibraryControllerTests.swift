import Foundation
import LibraryKit
import SwiftData
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
