import Foundation
import Testing
@testable import ProviderKit

@Suite("CUEToolsDB")
struct CUEToolsDBTests {

    // Trimmed real response for Miles Davis "Walkin'" (2026-09-20).
    static let walkinXML = """
    <ctdb xmlns="http://db.cuetools.net/ns/mmd-1.0#" xmlns:ext="http://db.cuetools.net/ns/ext-1.0#">
     <entry confidence="42" crc32="534054fd" hasparity="http://p.cuetools.net/1310779" id="1310779" npar="8" stride="5880" syndrome="cum06mLJ3PF1no7KpkMu1A==" toc="37:60712:98154:119544:139349:170557" trackcrcs="fe1b0b1d 1b8c2736 30f99024 40265ae9 f52a6619" />
     <entry confidence="3" crc32="deadbeef" id="99" npar="8" stride="5880" toc="37:60712:98154:119544:139349:170557" trackcrcs="00000001 1b8c2736 30f99024 40265ae9 00000005" />
     <metadata album="Walkin’" artist="Miles Davis All Stars" barcode="4988002013944" disccount="1" discname="" discnumber="1" id="86678562-ea2d-4be6-9763-92ac10aec3e1" relevance="81" source="musicbrainz" year="1957">
      <track artist="Miles Davis" name="Walkin&apos;" />
      <track artist="Miles Davis" name="Blue &apos;n&apos; Boogie" />
      <track artist="Miles Davis" name="Solar" />
      <track artist="Miles Davis" name="You Don&apos;t Know What Love Is" />
      <track artist="Miles Davis" name="Love Me or Leave Me" />
      <label catno="VDJ-1541" name="Prestige" />
      <release country="JP" date="1986-03-21" />
     </metadata>
     <metadata album="Walkin&apos;" artist="Miles Davis" disccount="1" discname="" discnumber="1" id="066c73cc-904c-3b10-a6c2-7eaa63f632cd" infourl="https://www.amazon.com/gp/product/B00000K0YB" relevance="81" source="musicbrainz" year="1957">
      <track name="Walkin&apos;" />
      <label catno="VICJ-60264" name="Prestige" />
      <release country="JP" date="1991-02-03" />
     </metadata>
    </ctdb>
    """

    @Test func parsesEntriesAndMetadata() throws {
        let r = try CUEToolsDBClient.parse(Data(Self.walkinXML.utf8))
        #expect(r.entries.count == 2)
        let e = try #require(r.bestEntry)
        #expect(e.id == "1310779")
        #expect(e.confidence == 42)
        #expect(e.discCRC32 == 0x534054fd)
        #expect(e.trackCRC32s == [0xfe1b0b1d, 0x1b8c2736, 0x30f99024, 0x40265ae9, 0xf52a6619])
        #expect(e.hasParity)
        #expect(!r.entries[1].hasParity)
        #expect(r.totalConfidence == 45)

        #expect(r.metadata.count == 2)
        let m = r.metadata[0]
        #expect(m.source == "musicbrainz")
        #expect(m.id == "86678562-ea2d-4be6-9763-92ac10aec3e1")
        #expect(m.album == "Walkin’")
        #expect(m.artist == "Miles Davis All Stars")
        #expect(m.barcode == "4988002013944")
        #expect(m.label == "Prestige")
        #expect(m.catalogNumber == "VDJ-1541")
        #expect(m.country == "JP")
        #expect(m.releaseDate == "1986-03-21")
        #expect(m.year == "1957")
        #expect(m.tracks.count == 5)
        #expect(m.tracks[1].name == "Blue 'n' Boogie")
        #expect(m.tracks[1].artist == "Miles Davis")
        #expect(r.metadata[1].barcode == nil)
        #expect(r.metadata[1].tracks.count == 1)
    }

    @Test func verifiesAgainstEntries() throws {
        let r = try CUEToolsDBClient.parse(Data(Self.walkinXML.utf8))
        let exact = CUEToolsDBClient.verify(
            trackCRC32s: [0xfe1b0b1d, 0x1b8c2736, 0x30f99024, 0x40265ae9, 0xf52a6619],
            discCRC32: 0x534054fd,
            response: r
        )
        #expect(exact.allTracksMatch)
        #expect(exact.discMatchesBestEntry)
        #expect(exact.tracks[0].matchedConfidence == 42)
        #expect(exact.tracks[1].matchedConfidence == 45)   // both entries share track 2

        let offsetRip = CUEToolsDBClient.verify(
            trackCRC32s: [0x11111111, 0x1b8c2736, 0x30f99024, 0x40265ae9, 0x22222222],
            discCRC32: 0x0,
            response: r
        )
        #expect(!offsetRip.allTracksMatch)
        #expect(offsetRip.matchedTrackCount == 3)
        #expect(!offsetRip.discMatchesBestEntry)
        #expect(offsetRip.tracks[0].bestEntryMatches == false)
        #expect(offsetRip.tracks[1].bestEntryMatches == true)
    }

    @Test func rejectsGarbage() {
        #expect(throws: CUEToolsDBClient.CTDBError.invalidResponse) {
            try CUEToolsDBClient.parse(Data("<html>nope</html>".utf8))
        }
        #expect(throws: CUEToolsDBClient.CTDBError.invalidResponse) {
            try CUEToolsDBClient.parse(Data("not xml".utf8))
        }
    }

    // Live lookup, only when DRTAGGER_NETWORK_TESTS=1.
    @Test func liveLookupIfEnabled() async throws {
        guard ProcessInfo.processInfo.environment["DRTAGGER_NETWORK_TESTS"] == "1" else { return }
        let client = CUEToolsDBClient(userAgent: "drtagger-mac-tests/0.1 (+https://drtagger.priet.us)")
        let r = try await client.lookup(toc: "37:60712:98154:119544:139349:170557")
        #expect(r.entries.contains { $0.id == "1310779" })
        #expect(r.metadata.contains { $0.barcode == "4988002013944" })
    }
}
