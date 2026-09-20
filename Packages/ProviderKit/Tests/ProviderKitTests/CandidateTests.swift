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
