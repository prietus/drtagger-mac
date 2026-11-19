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


@Suite struct ReleaseImageParsingTests {
    @Test func discogsImagesAndMusicBrainzLinks() {
        let discogs = Data(#"{"images":[{"type":"secondary","uri":"https://i.discogs.com/b.jpg","uri150":"https://i.discogs.com/b150.jpg","width":600,"height":600},{"type":"primary","uri":"https://i.discogs.com/a.jpg","width":1200,"height":1190}]}"#.utf8)
        let images = DiscogsClient.parseImages(discogs)
        #expect(images.map(\.url.lastPathComponent) == ["a.jpg", "b.jpg"] && images[0].isPrimary && images[1].thumbnail?.lastPathComponent == "b150.jpg")
        let rels = Data(#"{"relations":[{"type":"amazon asin","url":{"resource":"https://www.amazon.com/x"}},{"type":"discogs","url":{"resource":"https://www.discogs.com/release/406222"}},{"type":"discogs","url":{"resource":"https://www.discogs.com/es/release/123-Some-Title"}}]}"#.utf8)
        #expect(MusicBrainzClient.discogsIDs(fromURLRels: rels) == ["406222", "123"])
    }
}


@Suite struct DiscogsReleaseMappingTests {
    @Test func barcodeCatalogsAndMedium() throws {
        let json = #"{"id":27786006,"title":"The Power To Believe","year":2023,"country":"Japan","artists":[{"name":"King Crimson"}],"labels":[{"name":"Discipline Global Mobile","catno":"POCS-1950"},{"name":"Universal","catno":"none"}],"formats":[{"name":"CD","descriptions":["Album","Reissue"]}],"identifiers":[{"type":"Barcode","value":"4 988031 573259"},{"type":"Matrix / Runout","value":"POCS-1929 1T"}],"tracklist":[{"type_":"track","position":"1","title":"A Cappella","duration":"0:44"},{"type_":"heading","position":"","title":"Bonus Tracks:","duration":""},{"type_":"track","position":"2","title":"Superslow","duration":"3:38"}]}"#
        let c = try DiscogsClient.decodeRelease(Data(json.utf8))
        #expect(c.barcode == "4988031573259")
        #expect(c.catalogNumber == "POCS-1950")
        #expect(c.media.count == 1 && c.media[0].tracks.count == 2 && c.allTracks.map(\.durationMS) == [44000, 218000])
    }
}

@Suite struct CatalogRangeTests {
    @Test func rangesAndJoinersExpandForMatching() {
        let box = Candidate(source: .discogs, providerID: "14837607", title: "5 Great Operas", artist: "Various",
                            catalogNumber: "ESSD-90109/13 & ESSG-90114/17")
        #expect(box.matchingCatalogNumbers == ["ESSD-90109", "ESSD-90110", "ESSD-90111", "ESSD-90112", "ESSD-90113",
                                               "ESSG-90114", "ESSG-90115", "ESSG-90116", "ESSG-90117"])
        #expect(box.catalogNumbers == ["ESSD-90109/13 & ESSG-90114/17"], "tags keep the release's spelling")
        let tilde = Candidate(source: .musicbrainz, providerID: "t", title: "X", artist: "Y", catalogNumber: "TOGE-12061~3, B0035163-06")
        #expect(tilde.matchingCatalogNumbers == ["TOGE-12061", "TOGE-12062", "TOGE-12063", "B0035163-06"])
        let padded = Candidate(source: .musicbrainz, providerID: "p", title: "X", artist: "Y", catalogNumber: "ABC-0098/101")
        #expect(padded.matchingCatalogNumbers == ["ABC-0098", "ABC-0099", "ABC-0100", "ABC-0101"])
        // Not ranges: a slash between words, a shorter "end", a huge span.
        for odd in ["AS-57 / B0009784-02", "SRCS 1234/0", "X-1/999"] {
            let c = Candidate(source: .musicbrainz, providerID: "o", title: "X", artist: "Y", catalogNumber: odd)
            #expect(c.matchingCatalogNumbers == [odd], "\(odd)")
        }
    }
}
