import Testing
import Foundation
@testable import FLACKit

@Suite("FLAC parsing")
struct FLACFileTests {

    @Test("rejects non-FLAC data")
    func rejectsNonFLAC() {
        let garbage = Data([0x00, 0x01, 0x02, 0x03, 0x04])
        #expect(throws: FLACError.notAFLACFile) {
            try FLACFile(data: garbage)
        }
    }

    @Test("rejects truncated header")
    func rejectsTruncated() {
        let tiny = Data([0x66, 0x4C])
        #expect(throws: FLACError.truncated) {
            try FLACFile(data: tiny)
        }
    }

    @Test("parses a real FLAC fixture if present")
    func parsesFixture() throws {
        guard let url = Bundle.module.url(forResource: "tone", withExtension: "flac") else {
            return
        }
        let file = try FLACFile(url: url)
        #expect(file.streamInfo.sampleRate > 0)
        #expect(file.streamInfo.channels >= 1 && file.streamInfo.channels <= 8)
        #expect(file.streamInfo.bitsPerSample >= 4 && file.streamInfo.bitsPerSample <= 32)
        #expect(file.streamInfo.md5Signature.count == 16)
    }

    @Test("dump fixture contents")
    func dumpFixture() throws {
        guard let url = Bundle.module.url(forResource: "tone", withExtension: "flac") else {
            return
        }
        let file = try FLACFile(url: url)
        let si = file.streamInfo
        var out = "\n== STREAMINFO ==\n"
        out += "  rate=\(si.sampleRate) ch=\(si.channels) bits=\(si.bitsPerSample)\n"
        out += "  samples=\(si.totalSamples) duration=\(String(format: "%.2f", si.durationSeconds))s\n"
        out += "  md5=\(si.md5Signature.map { String(format: "%02x", $0) }.joined())\n"
        out += "  audioOffset=\(file.audioFrameOffset)\n== BLOCKS ==\n"
        for b in file.blocks {
            out += "  \(b.type) \(b.payload.length)B\(b.isLast ? " LAST" : "")\n"
        }
        if let vc = file.vorbisComment {
            out += "== VORBIS_COMMENT ==\n  vendor: \(vc.vendor)\n"
            for (n, v) in vc.fields {
                let short = v.count > 80 ? String(v.prefix(80)) + "…" : v
                out += "  \(n)=\(short)\n"
            }
        }
        Issue.record(Comment(rawValue: out))
    }
}
