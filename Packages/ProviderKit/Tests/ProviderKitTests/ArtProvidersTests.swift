import Foundation
import Testing
@testable import ProviderKit

@Suite("Art providers parsing")
struct ArtProvidersParsingTests {

    @Test func parsesCoverArtArchive() throws {
        let json = """
        {"images":[{"id":123,"image":"https://archive.org/x/front.jpg","front":true,"back":false,"types":["Front"],"comment":"",
        "thumbnails":{"250":"https://a/250.jpg","500":"https://a/500.jpg","1200":"https://a/1200.jpg","small":"https://a/250.jpg","large":"https://a/500.jpg"}},
        {"id":124,"image":"https://archive.org/x/back.jpg","front":false,"back":true,"types":["Back","Spine"],"thumbnails":{}}]}
        """
        let images = try CoverArtArchiveClient.parse(Data(json.utf8))
        #expect(images.count == 2)
        #expect(images[0].isFront)
        #expect(images[0].large?.absoluteString == "https://a/1200.jpg")
        #expect(images[0].comment == nil)
        #expect(images[1].isBack)
        #expect(images[1].types == ["Back", "Spine"])
        #expect(images[1].large == nil)
        #expect(CoverArtArchiveClient.frontURL(releaseID: "abc").absoluteString == "https://coverartarchive.org/release/abc/front-1200")
    }

    @Test func parsesITunes() throws {
        let json = """
        {"resultCount":1,"results":[{"collectionId":42,"artistName":"Miles Davis","collectionName":"Walkin'","releaseDate":"1957-01-01T08:00:00Z",
        "trackCount":5,"country":"USA","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/Music/v4/abc/source/100x100bb.jpg"}]}
        """
        let albums = try ITunesSearchClient.parse(Data(json.utf8))
        #expect(albums.count == 1)
        #expect(albums[0].artist == "Miles Davis")
        #expect(albums[0].releaseDate == "1957-01-01")
        #expect(albums[0].artworkURL3000.absoluteString.hasSuffix("/3000x3000bb.jpg"))
        #expect(albums[0].artworkURL1500.absoluteString.hasSuffix("/1500x1500bb.jpg"))
    }

    @Test func parsesDeezer() throws {
        let json = """
        {"data":[{"id":7,"title":"Walkin'","nb_tracks":5,"cover_xl":"https://e-cdns/1000x1000.jpg","cover_big":"https://e-cdns/500x500.jpg","artist":{"name":"Miles Davis"}}],"total":1}
        """
        let albums = try DeezerClient.parse(Data(json.utf8))
        #expect(albums.count == 1)
        #expect(albums[0].id == 7)
        #expect(albums[0].artist == "Miles Davis")
        #expect(albums[0].coverXL?.absoluteString == "https://e-cdns/1000x1000.jpg")
    }
}

// Live checks against the real services; DRTAGGER_NETWORK_TESTS=1.
@Suite("Providers live", .serialized)
struct ProvidersLiveTests {
    static var enabled: Bool { ProcessInfo.processInfo.environment["DRTAGGER_NETWORK_TESTS"] == "1" }
    static let ua = "drtagger-mac-tests/0.1 (+https://drtagger.priet.us)"

    @Test func musicBrainzDiscIDReturnsTheExactRelease() async throws {
        guard Self.enabled else { return }
        let mb = MusicBrainzClient(userAgent: Self.ua)
        // Miles Davis All Stars – Walkin' (JVC XRCD): disc id from the real rip.
        let releases = try await mb.lookupDiscID("iOSL4j4VX_YutvVxL4QjWVsVEJE-", toc: "1 5 170707 187 60862 98304 119694 139499")
        #expect(!releases.isEmpty)
        let r = try #require(releases.first)
        #expect(r.title.lowercased().contains("walkin"))
        #expect(r.media.count == 1)
        #expect(r.media[0].tracks.count == 5)
        #expect(releases.count >= 5, "fuzzy TOC match should list several editions")
        #expect(r.media[0].tracks[0].recordingID != nil)
        #expect(r.media[0].tracks[0].durationMS != nil)
    }

    @Test func musicBrainzBarcodeSearch() async throws {
        guard Self.enabled else { return }
        let mb = MusicBrainzClient(userAgent: Self.ua)
        let releases = try await mb.searchByBarcode("4988002013944")
        #expect(releases.contains { $0.barcode == "4988002013944" })
    }

    @Test func coverArtArchiveListsImages() async throws {
        guard Self.enabled else { return }
        // Miles Davis – Kind of Blue, a release with known artwork.
        let caa = CoverArtArchiveClient(userAgent: Self.ua)
        let images = try await caa.images(releaseID: "fc26c1a8-ac6d-3e3c-9e9b-1f4c7f7c3ea1")
        _ = images   // may legitimately be empty for this MBID; just must not throw
        let none = try await caa.images(releaseID: "00000000-0000-0000-0000-000000000000")
        #expect(none.isEmpty)
    }

    @Test func iTunesAndDeezerFindArtwork() async throws {
        guard Self.enabled else { return }
        let itunes = ITunesSearchClient(userAgent: Self.ua)
        let albums = try await itunes.searchAlbums(artist: "Miles Davis", album: "Kind of Blue")
        #expect(albums.contains { $0.title.lowercased().contains("kind of blue") })
        let deezer = DeezerClient(userAgent: Self.ua)
        let dz = try await deezer.searchAlbums(artist: "Miles Davis", album: "Kind of Blue")
        #expect(dz.contains { $0.title.lowercased().contains("kind of blue") && $0.coverXL != nil })
    }
}

extension ProvidersLiveTests {
    @Test func catalogVariantsFindTheHybridSACD() async throws {
        guard Self.enabled else { return }
        let mb = MusicBrainzClient(userAgent: Self.ua)
        do {
            let rs = try await mb.searchByCatalog("CAPP139 SA")
            print("catalog search returned \(rs.count): \(rs.map { ($0.year ?? "?", $0.mediaFormat ?? "?", $0.catalogNumber ?? "?") })")
            #expect(rs.contains { $0.catalogNumbers.contains("CAPP 139 SA") })
            #expect(rs.contains { $0.mediaFormat?.contains("SACD") == true })
        } catch {
            Issue.record("searchByCatalog threw: \(error)")
        }
    }
}

@Suite("Key checks (network)") struct KeyCheckTests {
    static var network: Bool { ProcessInfo.processInfo.environment["DRTAGGER_NETWORK_TESTS"] == "1" }
    static let ua = "drtagger-mac-tests/0.1 (+https://drtagger.priet.us)"

    @Test func wrongKeysAreRejected() async {
        guard Self.network else { return }
        let acoust = await AcoustIDClient(clientKey: "definitely-not-a-key", userAgent: Self.ua).validateKey()
        if case .invalid = acoust {} else { Issue.record("AcoustID: \(acoust)") }
        let discogs = await DiscogsClient(userAgent: Self.ua, token: "definitely-not-a-token").validateToken()
        if case .invalid = discogs {} else { Issue.record("Discogs: \(discogs)") }
        let fanart = await FanartClient(apiKey: "definitely-not-a-key", userAgent: Self.ua).validateKey()
        if case .invalid = fanart {} else { Issue.record("fanart.tv: \(fanart)") }
        #expect(await AcoustIDClient(clientKey: "", userAgent: Self.ua).validateKey() == .invalid("No key entered"))
    }
}
