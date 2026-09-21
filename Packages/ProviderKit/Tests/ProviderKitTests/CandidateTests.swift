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
