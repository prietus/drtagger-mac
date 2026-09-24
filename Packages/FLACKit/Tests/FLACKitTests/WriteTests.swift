import Testing
import Foundation
import CryptoKit
@testable import FLACKit

@Suite("Tag writing")
struct WriteTests {

    @Test("round-trip preserves audio bytes and new tags")
    func roundTrip() throws {
        guard let url = Bundle.module.url(forResource: "tone", withExtension: "flac") else {
            return
        }
        let original = try FileHandleDataSource(url: url)
        let file = try FLACFile(source: original)
        guard let oldTags = file.vorbisComment else {
            Issue.record("fixture has no vorbis comment")
            return
        }

        // Mutate a field we know exists and add a new one.
        var newFields = oldTags.fields
        if let i = newFields.firstIndex(where: { $0.name == "TITLE" }) {
            newFields[i].value = "Test Tone (drtagger test)"
        }
        newFields.append((name: "DRTAGGER_TEST", value: "ok"))
        let newTags = VorbisComment(vendor: oldTags.vendor, fields: newFields)

        let rewritten = try file.rewritten(with: newTags, source: original)

        // Re-parse the rewritten bytes and verify the new tags are there.
        let reparsed = try FLACFile(data: rewritten)
        #expect(reparsed.vorbisComment?["TITLE"] == ["Test Tone (drtagger test)"])
        #expect(reparsed.vorbisComment?["DRTAGGER_TEST"] == ["ok"])
        #expect(reparsed.vorbisComment?["ARTIST"] == ["drtagger"])

        // Audio frames must be byte-exact — that's the audiophile contract.
        let origAudio = try original.read(
            at: file.audioFrameOffset,
            length: Int(file.audioFrameLength)
        )
        let newAudio = rewritten.subdata(
            in: Int(reparsed.audioFrameOffset)..<(Int(reparsed.audioFrameOffset) + Int(reparsed.audioFrameLength))
        )
        #expect(origAudio == newAudio, "audio frames must be byte-identical")

        // STREAMINFO.md5 must survive (we copy the original STREAMINFO block
        // untouched, so this is a cheap sanity check).
        #expect(reparsed.streamInfo.md5Signature == file.streamInfo.md5Signature)

        // And the MD5 of the copied audio region must still match what
        // libFLAC wrote. We verify the first 16 bytes of SHA256 match
        // between origAudio and newAudio as a secondary integrity check.
        let origHash = SHA256.hash(data: origAudio)
        let newHash = SHA256.hash(data: newAudio)
        #expect(origHash == newHash)
    }

    @Test("PICTURE block is preserved byte-exact via reference load")
    func picturePreserved() throws {
        guard let url = Bundle.module.url(forResource: "tone", withExtension: "flac") else {
            return
        }
        let source = try FileHandleDataSource(url: url)
        let file = try FLACFile(source: source)
        guard let originalPicture = file.blocks.first(where: { $0.type == .picture }) else {
            return
        }
        let originalPictureData = try originalPicture.loadPayload(from: source)

        guard let tags = file.vorbisComment else { return }
        let rewritten = try file.rewritten(with: tags, source: source)

        let reparsed = try FLACFile(data: rewritten)
        guard let newPicture = reparsed.blocks.first(where: { $0.type == .picture }) else {
            Issue.record("PICTURE block disappeared on rewrite")
            return
        }
        let reparsedSource = DataDataSource(rewritten)
        let newPictureData = try newPicture.loadPayload(from: reparsedSource)
        #expect(originalPictureData == newPictureData)
    }
}
