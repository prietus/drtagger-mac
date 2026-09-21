import Foundation
import Testing
@testable import ProviderKit

@Suite struct CandidateTests {
    @Test func idCombinesSourceAndProviderID() {
        let c = Candidate(source: .musicbrainz, providerID: "abc", title: "T", artist: "A")
        #expect(c.id == "musicbrainz:abc")
    }

    @Test func providerErrorDescriptions() {
        #expect(ProviderError.httpError(503).errorDescription?.contains("503") == true)
        #expect(ProviderError.rateLimited(retryAfterSeconds: 2).errorDescription?.contains("2 s") == true)
    }
}


@Suite struct CatalogQueryTests {
    @Test func catalogQueryCoversSpellings() {
        let q = MusicBrainzClient.catalogQuery("CAPP139 SA")
        #expect(q.contains("catno:\"CAPP139 SA\""))
        #expect(q.contains("catno:\"CAPP 139 SA\""))
        #expect(q.contains("catno:\"CAPP-139-SA\""))
        #expect(q.contains("catno:\"CAPP139SA\""))
        #expect(q.contains("catno:CAPP139*"))
        #expect(q.components(separatedBy: " OR ").count == 5)
        let simple = MusicBrainzClient.catalogQuery("PD 83889")
        #expect(simple.contains("catno:\"PD 83889\""))
        #expect(simple.contains("catno:\"PD-83889\""))
        #expect(simple.contains("catno:PD83889*"))
    }
}


@Suite struct PlausibleTrackCountTests {
    @Test func hybridLayersCountOnce() {
        let hybrid = Candidate(source: .musicbrainz, providerID: "h", title: "Aja", artist: "Steely Dan", trackCount: 14,
                               media: [CandidateMedium(position: 1, format: "Hybrid SACD (CD layer)", trackCount: 7),
                                       CandidateMedium(position: 2, format: "Hybrid SACD (SACD layer, 2 channels)", trackCount: 7)])
        #expect(hybrid.plausibleTrackCounts == [14, 7])
        let twoCD = Candidate(source: .musicbrainz, providerID: "d", title: "X", artist: "Y", trackCount: 20,
                              media: [CandidateMedium(position: 1, format: "CD", trackCount: 10), CandidateMedium(position: 2, format: "CD", trackCount: 10)])
        #expect(twoCD.plausibleTrackCounts == [20])
    }
}


@Suite struct ReleaseDetailDecodingTests {
    static let json = """
    {"id":"rel-1","title":"Kind of Blue","date":"1959-08-17","country":"US","status":"Official","barcode":"074646493526",
     "text-representation":{"script":"Latn","language":"eng"},
     "artist-credit":[{"name":"Miles Davis","joinphrase":"","artist":{"id":"art-1","name":"Miles Davis","sort-name":"Davis, Miles"}}],
     "label-info":[{"catalog-number":"CK 64935","label":{"name":"Columbia"}}],
     "release-group":{"id":"rg-1","primary-type":"Album","secondary-types":["Live"],"first-release-date":"1959-08-17"},
     "media":[{"position":1,"format":"CD","track-count":1,"tracks":[
       {"id":"trk-1","number":"1","position":1,"title":"So What","length":562000,
        "artist-credit":[{"name":"Miles Davis","joinphrase":" feat. ","artist":{"id":"art-1","name":"Miles Davis","sort-name":"Davis, Miles"}},
                         {"name":"Bill Evans","joinphrase":"","artist":{"id":"art-2","name":"Bill Evans","sort-name":"Evans, Bill"}}],
        "recording":{"id":"rec-1","title":"So What","length":562000,"isrcs":["USSM15900001"],
          "relations":[
            {"type":"instrument","direction":"backward","target-type":"artist","attributes":["trumpet"],"artist":{"id":"art-1","name":"Miles Davis","sort-name":"Davis, Miles"}},
            {"type":"instrument","direction":"backward","target-type":"artist","attributes":["piano"],"artist":{"id":"art-2","name":"Bill Evans","sort-name":"Evans, Bill"}},
            {"type":"producer","direction":"backward","target-type":"artist","attributes":[],"artist":{"id":"art-3","name":"Teo Macero","sort-name":"Macero, Teo"}},
            {"type":"performance","direction":"forward","target-type":"work","attributes":[],
             "work":{"id":"work-1","title":"So What","relations":[
               {"type":"composer","direction":"backward","target-type":"artist","artist":{"id":"art-1","name":"Miles Davis","sort-name":"Davis, Miles"}}]}}
          ]}}]}]}
    """

    @Test func decodesCreditsISRCsAndWorks() throws {
        let c = try MusicBrainzClient.decodeRelease(Data(Self.json.utf8))
        #expect(c.artist == "Miles Davis")
        #expect(c.artistSort == "Davis, Miles")
        #expect(c.artistIDs == ["art-1"])
        #expect(c.secondaryTypes == ["Live"])
        #expect(c.firstReleaseDate == "1959-08-17")
        #expect(c.script == "Latn")
        let t = try #require(c.allTracks.first)
        #expect(t.artist == "Miles Davis feat. Bill Evans")
        #expect(ArtistCredit.sortJoined(t.artistCredits) == "Davis, Miles feat. Evans, Bill")
        #expect(t.isrcs == ["USSM15900001"])
        #expect(t.works.map(\.title) == ["So What"])
        #expect(t.credits.contains(TrackCredit(role: "trumpet", name: "Miles Davis")))
        #expect(t.credits.contains(TrackCredit(role: "producer", name: "Teo Macero")))
        #expect(t.credits.contains(TrackCredit(role: "composer", name: "Miles Davis")))

        // Round trip through Codable and decoding of an old, field-less blob.
        let data = try JSONEncoder().encode(c)
        #expect(try JSONDecoder().decode(Candidate.self, from: data) == c)
        let old = Data(#"{"source":"musicbrainz","providerID":"x","title":"T","artist":"A","tracks":[{"position":1,"title":"a"}]}"#.utf8)
        let decoded = try JSONDecoder().decode(Candidate.self, from: old)
        #expect(decoded.artistCredits.isEmpty && decoded.tracks.first?.isrcs.isEmpty == true)
    }
}
