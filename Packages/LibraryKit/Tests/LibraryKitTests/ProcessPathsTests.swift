import Foundation
import Testing
@testable import LibraryKit

struct ProcessPathsTests {
    @Test func accentedPathsBecomeASCIILinksToTheSameFile() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "drtagger-pp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.path + "/01 Barón Rojo - ¿Qué puedo hacer?.flac"
        #expect(FileManager.default.createFile(atPath: file, contents: Data("x".utf8)))

        #expect(ProcessPaths.argument("/tmp/plain.flac") == "/tmp/plain.flac")
        #expect(ProcessPaths.argument("-i") == "-i")
        let linked = ProcessPaths.argument(file)
        #expect(linked.allSatisfy(\.isASCII) && linked.hasSuffix(".flac"))
        #expect(try String(contentsOfFile: linked, encoding: .utf8) == "x")
        #expect(ProcessPaths.argument(file) == linked, "one link per path")

        let output = ProcessPaths.argument(dir.path + "/Ñandú/out.flac")
        #expect(output == ProcessPaths.argument(dir.path + "/Ñandú/out.flac"))
    }
}
