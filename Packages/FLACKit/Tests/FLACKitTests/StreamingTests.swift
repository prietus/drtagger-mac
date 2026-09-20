import Testing
import Foundation
@testable import FLACKit

// The whole point of the DataSource refactor: tag-only parsing of a real
// FLAC must touch only a few KB of the file, even when the file carries a
// huge embedded PICTURE block. Over SMB/WebDAV this difference is the
// difference between "instant" and "30 seconds of spinner".

@Suite("Streaming reads")
struct StreamingTests {

    @Test("tag-only parse stays under 16KB for typical files")
    func tagParseIsSmall() throws {
        guard let url = Bundle.module.url(forResource: "sample", withExtension: "flac") else {
            return
        }
        let inner = try FileHandleDataSource(url: url)
        let counting = CountingDataSource(inner)
        let file = try FLACFile(source: counting)

        #expect(file.vorbisComment != nil)
        #expect(counting.bytesRead < 16 * 1024,
                "tag parse read \(counting.bytesRead) bytes in \(counting.reads) reads")

        // PICTURE must have been recorded as a reference, not inlined, or
        // the whole optimization is meaningless.
        let picture = file.blocks.first { $0.type == .picture }
        if let picture {
            if case .inline = picture.payload {
                Issue.record("PICTURE block was inlined instead of referenced")
            }
        }
    }

    @Test("loadPayload on reference block reads from source")
    func lazyPictureLoad() throws {
        guard let url = Bundle.module.url(forResource: "sample", withExtension: "flac") else {
            return
        }
        let source = try FileHandleDataSource(url: url)
        let file = try FLACFile(source: source)
        guard let picture = file.blocks.first(where: { $0.type == .picture }) else {
            return
        }
        let data = try picture.loadPayload(from: source)
        #expect(data.count == picture.payload.length)
        #expect(data.count > 1024)
    }
}
