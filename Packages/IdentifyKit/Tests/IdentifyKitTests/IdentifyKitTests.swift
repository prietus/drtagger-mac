import Foundation
import LibraryKit
import ProviderKit
import SplitKit
import Testing
@testable import IdentifyKit

enum TestEnv {
    static let samples = URL(fileURLWithPath: NSString(string: "~/mactagger-samples").expandingTildeInPath)
    static var network: Bool { ProcessInfo.processInfo.environment["DRTAGGER_NETWORK_TESTS"] == "1" }
    static var acoustIDKey: String? { ProcessInfo.processInfo.environment["DRTAGGER_ACOUSTID_KEY"] }
    static let ua = "drtagger-mac-tests/0.1 (+https://drtagger.priet.us)"

    static var ffmpeg: FFmpegTool? {
        let here = URL(fileURLWithPath: #filePath)
        let repo = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for dir in [repo.appending(path: "Vendor/ffmpeg"), URL(fileURLWithPath: "/opt/homebrew/bin")] {
            let f = dir.appending(path: "ffmpeg"), p = dir.appending(path: "ffprobe")
            if FileManager.default.isExecutableFile(atPath: f.path), FileManager.default.isExecutableFile(atPath: p.path) {
                return FFmpegTool(ffmpeg: f, ffprobe: p)
            }
        }
        return nil
    }

    static func album(_ relativeFolder: String) -> DetectedAlbum? {
        let url = samples.appending(path: relativeFolder)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return LibraryScanner().scan([url]).albums.first
    }
}

@Suite("CatalogNumberParser")
struct CatalogNumberParserTests {
    @Test func extractsJapaneseAndWesternCodes() {
        let lines = ["SICP-1700  ¥2,500", "Made in Japan  UICY 40164", "PD 83889", "CD 12", "TOTAL TIME 45:12", "prestige-7142", "VDJ~1541"]
        let found = CatalogNumberParser.extract(from: lines).map(\.formatted)
        #expect(found.contains("SICP-1700"))
        #expect(found.contains("UICY-40164"))
        #expect(found.contains("PD-83889"))
        #expect(found.contains("PRESTIGE-7142"))
        #expect(found.contains("VDJ-1541"))
        #expect(!found.contains("CD-12"))
        #expect(!found.contains("TIME-45"))
        #expect(CatalogNumberParser.normalize("sicp 1700") == "SICP1700")
        #expect(CatalogNumberParser.normalize("SICP-1700") == "SICP1700")
    }
}

@Suite("MatchScorer")
struct MatchScorerTests {

    static func candidate(tracks: [Int], barcode: String? = nil, catno: String? = nil, discID: String? = nil, artist: String = "David Bowie", title: String = "Diamond Dogs") -> Candidate {
        let ct = tracks.enumerated().map { CandidateTrack(position: $0.offset + 1, title: "T\($0.offset + 1)", durationMS: $0.element * 1000) }
        return Candidate(
            source: .musicbrainz, providerID: UUID().uuidString, title: title, artist: artist, year: "1984",
            catalogNumber: catno, trackCount: tracks.count, tracks: ct, barcode: barcode,
            media: [CandidateMedium(position: 1, format: "CD", tracks: ct, discIDs: discID.map { [$0] } ?? [])]
        )
    }

    static func signals(durations: [Double], barcode: String? = nil, catno: String? = nil, discID: String? = nil) -> AlbumSignals {
        var s = AlbumSignals()
        s.tracks = durations.enumerated().map { LocalTrack(index: $0.offset, discNumber: 1, title: nil, durationSeconds: $0.element, url: nil) }
        if let barcode { s.barcodes = [SignalValue(barcode, origin: .artwork)] }
        if let catno { s.catalogNumbers = [SignalValue(catno, origin: .artwork)] }
        s.discID = discID
        s.artistHint = "David Bowie"
        s.albumHint = "Diamond Dogs"
        s.yearHint = "1984"
        return s
    }

    @Test func barcodePlusDurationsIsConfidentOnlyWithASecondSignal() {
        let c = Self.candidate(tracks: [200, 180, 240], barcode: "0035628388926", catno: "PD 83889")
        let one = MatchScorer.score(c, signals: Self.signals(durations: [201, 179, 241], barcode: "035628388926"), origins: [.barcode], fingerprintVote: nil, fingerprintedTracks: 0)
        #expect(one.confidence == .likely)
        #expect(one.reasons.contains { $0.hasPrefix("Barcode") })
        #expect(one.durationFit! > 0.8)

        let two = MatchScorer.score(c, signals: Self.signals(durations: [201, 179, 241], barcode: "035628388926", catno: "pd-83889"), origins: [.barcode, .catalogNumber], fingerprintVote: nil, fingerprintedTracks: 0)
        #expect(two.confidence == .confident)
        #expect(two.score > one.score)
    }

    @Test func trackCountMismatchIsNeverConfident() {
        let c = Self.candidate(tracks: [200, 180, 240, 100], barcode: "0035628388926")
        let s = MatchScorer.score(c, signals: Self.signals(durations: [201, 179, 241], barcode: "0035628388926", discID: "x"), origins: [.barcode, .discID], fingerprintVote: nil, fingerprintedTracks: 0)
        #expect(s.trackCountMatches == false)
        #expect(s.confidence < .likely)
    }

    @Test func fingerprintCoverageAndDiscID() {
        let c = Self.candidate(tracks: [200, 180, 240], discID: "abc")
        let vote = ReleaseVote(releaseID: c.providerID, trackIndices: [0, 1, 2], bestScore: 0.98)
        let s = MatchScorer.score(c, signals: Self.signals(durations: [200, 180, 240], discID: "abc"), origins: [.discID, .fingerprint], fingerprintVote: vote, fingerprintedTracks: 3)
        #expect(s.confidence == .confident)
        #expect(s.fingerprintCoverage == 1)
        #expect(s.reasons.contains("Disc ID matches"))

        let far = Self.candidate(tracks: [300, 300, 300])
        let bad = MatchScorer.score(far, signals: Self.signals(durations: [200, 180, 240]), origins: [.textSearch], fingerprintVote: nil, fingerprintedTracks: 0)
        #expect(bad.confidence == .unlikely)
    }

    @Test func hybridSACDLayersAndFormatBonus() {
        let sacdLayer = [200, 180, 240].enumerated().map { CandidateTrack(position: $0.offset + 1, title: "T", durationMS: $0.element * 1000) }
        let hybrid = Candidate(
            source: .musicbrainz, providerID: "hybrid", title: "Aja", artist: "Steely Dan", year: "2024",
            catalogNumber: "B0035163-06, CAPP 139 SA", mediaFormat: "2×Hybrid SACD", trackCount: 6, tracks: sacdLayer,
            media: [CandidateMedium(position: 1, format: "Hybrid SACD (CD layer)", tracks: sacdLayer),
                    CandidateMedium(position: 2, format: "Hybrid SACD (SACD layer, 2 channels)", tracks: sacdLayer)]
        )
        var sacd = Self.signals(durations: [200, 180, 240], catno: "CAPP139 SA")
        sacd.isDSD = true
        sacd.artistHint = "Steely Dan"; sacd.albumHint = "Aja"; sacd.yearHint = nil
        let scored = MatchScorer.score(hybrid, signals: sacd, origins: [.catalogNumber], fingerprintVote: nil, fingerprintedTracks: 0)
        #expect(scored.trackCountMatches == true, "layers of one disc must not be summed")
        #expect(scored.reasons.contains("SACD edition"))
        #expect(scored.reasons.contains { $0.hasPrefix("Catalog number") })
        #expect(scored.confidence >= .likely)

        let vinyl = Candidate(source: .musicbrainz, providerID: "lp", title: "Aja", artist: "Steely Dan", mediaFormat: "12\" Vinyl", trackCount: 3, tracks: sacdLayer,
                              media: [CandidateMedium(position: 1, format: "12\" Vinyl", tracks: sacdLayer)])
        let lp = MatchScorer.score(vinyl, signals: sacd, origins: [.textSearch], fingerprintVote: nil, fingerprintedTracks: 0)
        #expect(lp.score < scored.score - 30)
        #expect(lp.reasons.contains { $0.hasPrefix("Not a SACD") })

        var cd = Self.signals(durations: [200, 180, 240])
        cd.sampleRate = 44100; cd.bitsPerSample = 16
        #expect(cd.localFormat == .cd)
        let lpForCD = MatchScorer.score(vinyl, signals: cd, origins: [.textSearch], fingerprintVote: nil, fingerprintedTracks: 0)
        #expect(lpForCD.reasons.contains("Vinyl cannot be the source of a CD rip"))
        let hybridForCD = MatchScorer.score(hybrid, signals: cd, origins: [.textSearch], fingerprintVote: nil, fingerprintedTracks: 0)
        #expect(hybridForCD.trackCountMatches == true)
        #expect(hybridForCD.reasons.contains("CD edition"))
    }

    @Test func folderHintsSeparateEditions() {
        // "Linkin Park - 2003 - Meteora 20th Anniversary Edition (MQA)" as the
        // collector reads it, with no track information at all.
        var s = AlbumSignals()
        s.artistHint = "Linkin Park"; s.albumHint = "Meteora"; s.yearHint = "2003"
        s.editionHint = "20th Anniversary Edition"; s.sourceHint = .digital
        let anniversary = Candidate(source: .musicbrainz, providerID: "a", title: "Meteora (20th Anniversary Edition)", artist: "Linkin Park",
                                    year: "2023", country: "XW", mediaFormat: "6×Digital Media", trackCount: 89,
                                    media: (1...6).map { CandidateMedium(position: $0, format: "Digital Media") })
        let original = Candidate(source: .musicbrainz, providerID: "o", title: "Meteora", artist: "Linkin Park", year: "2003", country: "US",
                                 mediaFormat: "CD", trackCount: 13, media: [CandidateMedium(position: 1, format: "CD")])
        let a = MatchScorer.score(anniversary, signals: s, origins: [.textSearch], fingerprintVote: nil, fingerprintedTracks: 0)
        let o = MatchScorer.score(original, signals: s, origins: [.textSearch], fingerprintVote: nil, fingerprintedTracks: 0)
        #expect(a.reasons.contains { $0.hasPrefix("Edition") && $0.hasSuffix("matches") })
        #expect(a.reasons.contains("Digital release, as the folder says"))
        #expect(o.reasons.contains { $0.hasSuffix("not mentioned") })
        #expect(a.score > o.score + 15)

        // "Diana Krall- All For You XRCD Japan": country and CD hints on a CD rip.
        var jp = AlbumSignals()
        jp.artistHint = "Diana Krall"; jp.albumHint = "All for You"; jp.countryHint = "JP"; jp.sourceHint = .cd
        jp.sampleRate = 44100; jp.bitsPerSample = 16
        let japan = Candidate(source: .musicbrainz, providerID: "j", title: "All for You", artist: "Diana Krall", year: "1996", country: "JP", mediaFormat: "CD", trackCount: 12)
        let us = Candidate(source: .musicbrainz, providerID: "u", title: "All for You", artist: "Diana Krall", year: "1996", country: "US", mediaFormat: "CD", trackCount: 12)
        let j = MatchScorer.score(japan, signals: jp, origins: [.textSearch], fingerprintVote: nil, fingerprintedTracks: 0)
        let u = MatchScorer.score(us, signals: jp, origins: [.textSearch], fingerprintVote: nil, fingerprintedTracks: 0)
        #expect(j.reasons.contains("Country JP matches"))
        #expect(j.score > u.score)

        // Edition year beats original year: "1974 - Diamond Dogs (1984, W. Germany, RCA PD83889)".
        var dd = AlbumSignals()
        dd.albumHint = "Diamond Dogs"; dd.yearHint = "1974"; dd.editionYearHint = "1984"; dd.countryHint = "DE"
        let p84 = Candidate(source: .musicbrainz, providerID: "84", title: "Diamond Dogs", artist: "David Bowie", year: "1984", country: "DE", mediaFormat: "CD")
        let p74 = Candidate(source: .musicbrainz, providerID: "74", title: "Diamond Dogs", artist: "David Bowie", year: "1974", country: "GB", mediaFormat: "12\" Vinyl")
        let s84 = MatchScorer.score(p84, signals: dd, origins: [.textSearch], fingerprintVote: nil, fingerprintedTracks: 0)
        let s74 = MatchScorer.score(p74, signals: dd, origins: [.textSearch], fingerprintVote: nil, fingerprintedTracks: 0)
        #expect(s84.reasons.contains("Edition year 1984"))
        #expect(s84.score > s74.score)

        #expect(MatchScorer.editionKeywords("20th Anniversary Edition") == ["20th", "anniversary"])
        #expect(MatchScorer.editionKeywords("Remastered") == ["remaster"])
    }

    @Test func formatCompatibilityTiers() {
        func cand(_ formats: [String], descriptions: [String] = []) -> Candidate {
            Candidate(source: .musicbrainz, providerID: formats.joined(), title: "X", artist: "Y",
                      mediaFormat: formats.first, formatDescriptions: descriptions,
                      media: formats.enumerated().map { CandidateMedium(position: $0.offset + 1, format: $0.element) })
        }
        let sacd = cand(["SACD"]), hybrid = cand(["Hybrid SACD (CD layer)", "Hybrid SACD (SACD layer, 2 channels)"])
        let cd = cand(["CD"]), vinyl = cand(["12\" Vinyl"]), digital = cand(["Digital Media"]), unknown = cand([])
        let box = cand(["12\" Vinyl", "CD", "DVD"]), cassette = cand(["Cassette"])
        let boxOnly = Candidate(source: .musicbrainz, providerID: "b", title: "X", artist: "Y", mediaFormat: "Box set")

        var iso = AlbumSignals(); iso.isDSD = true; iso.isSACDImage = true
        #expect(MatchScorer.formatCompatibility(sacd, signals: iso) == .fits)
        #expect(MatchScorer.formatCompatibility(hybrid, signals: iso) == .fits)
        #expect(MatchScorer.formatCompatibility(cd, signals: iso) == .unlikely)
        #expect(MatchScorer.formatCompatibility(digital, signals: iso) == .unlikely)
        #expect(MatchScorer.formatCompatibility(unknown, signals: iso) == .unknown, "no format on MusicBrainz is not evidence")
        #expect(MatchScorer.formatCompatibility(boxOnly, signals: iso) == .unknown)
        var sacdR = iso; sacdR.sourceHint = .digital
        #expect(MatchScorer.formatCompatibility(digital, signals: sacdR) == .fits, "SACD-R burnt from a DSD download")
        #expect(MatchScorer.formatCompatibility(sacd, signals: sacdR) == .fits)

        var dsf = AlbumSignals(); dsf.isDSD = true
        #expect(MatchScorer.formatCompatibility(digital, signals: dsf) == .fits, "loose DSF may be a download")
        #expect(MatchScorer.formatCompatibility(vinyl, signals: dsf) == .unlikely)

        var rip = AlbumSignals(); rip.sampleRate = 44100; rip.bitsPerSample = 16
        #expect(MatchScorer.formatCompatibility(cd, signals: rip) == .fits)
        #expect(MatchScorer.formatCompatibility(hybrid, signals: rip) == .fits, "CD layer of a hybrid")
        #expect(MatchScorer.formatCompatibility(sacd, signals: rip) == .unlikely, "SACD without a CD layer")
        #expect(MatchScorer.formatCompatibility(digital, signals: rip) == .fits, "16/44 downloads exist")
        #expect(MatchScorer.formatCompatibility(vinyl, signals: rip) == .unlikely)
        #expect(MatchScorer.formatCompatibility(box, signals: rip) == .fits, "any medium of a box set may match")
        #expect(MatchScorer.formatCompatibility(cassette, signals: rip) == .unlikely)
        var vinylRip = rip; vinylRip.sourceHint = .vinyl
        #expect(MatchScorer.formatCompatibility(vinyl, signals: vinylRip) == .fits, "the folder says vinyl")
        #expect(MatchScorer.formatCompatibility(cd, signals: vinylRip) == .unlikely)

        var hires = AlbumSignals(); hires.sampleRate = 96000; hires.bitsPerSample = 24
        #expect(MatchScorer.formatCompatibility(digital, signals: hires) == .fits)
        #expect(MatchScorer.formatCompatibility(vinyl, signals: hires) == .fits)
        #expect(MatchScorer.formatCompatibility(sacd, signals: hires) == .fits, "DSD converted to PCM")
        #expect(MatchScorer.formatCompatibility(cd, signals: hires) == .unlikely)
        var xrcd = hires; xrcd.sourceHint = .cd
        #expect(MatchScorer.formatCompatibility(cd, signals: xrcd) == .fits)

        let none = AlbumSignals()
        #expect(MatchScorer.formatCompatibility(cd, signals: none) == .unknown, "nothing known about the files")

        // Discogs-style descriptions count too.
        let discogs = Candidate(source: .discogs, providerID: "d", title: "X", artist: "Y", mediaFormat: "SACD", formatDescriptions: ["Hybrid", "Multichannel"])
        #expect(MatchScorer.formatCompatibility(discogs, signals: rip) == .fits)
    }

    @Test func setMembersMatchTheirMedium() {
        func medium(_ pos: Int, _ durations: [Int], discID: String? = nil) -> CandidateMedium {
            CandidateMedium(position: pos, format: "CD", tracks: durations.enumerated().map { CandidateTrack(position: $0.offset + 1, title: "T", durationMS: $0.element * 1000) }, discIDs: discID.map { [$0] } ?? [])
        }
        let box = Candidate(source: .musicbrainz, providerID: "box", title: "Box Set", artist: "Led Zeppelin", trackCount: 9,
                            media: [medium(1, [200, 210, 220], discID: "id1"), medium(2, [300, 310, 320], discID: "id2"), medium(3, [400, 410, 420], discID: "id3")])
        let single = Candidate(source: .musicbrainz, providerID: "single", title: "Box Set", artist: "Led Zeppelin", trackCount: 3, media: [medium(1, [300, 310, 320])])

        // Disc 2 alone, declared "2 of 3".
        var two = AlbumSignals()
        two.tracks = [300.0, 310, 320].enumerated().map { LocalTrack(index: $0.offset, discNumber: 2, title: nil, durationSeconds: $0.element, url: nil) }
        two.presentDiscs = [2]; two.declaredDiscTotal = 3; two.discCount = 3
        two.discIDs = [2: "id2"]
        two.artistHint = "Led Zeppelin"; two.albumHint = "Box Set"
        let b = MatchScorer.score(box, signals: two, origins: [.discID], fingerprintVote: nil, fingerprintedTracks: 0)
        #expect(b.trackCountMatches == true && (b.durationFit ?? 0) > 0.99, "medium 2 is compared, not the whole box")
        #expect(b.reasons.contains("Disc ID matches") && b.reasons.contains("3 discs"))
        let sgl = MatchScorer.score(single, signals: two, origins: [.textSearch], fingerprintVote: nil, fingerprintedTracks: 0)
        #expect(sgl.reasons.contains { $0.hasPrefix("Release has no disc 2") })
        #expect(b.score > sgl.score + 40)

        // Discs 1 and 3 of the box (2 missing): both IDs match, no penalty for the gap.
        var partial = AlbumSignals()
        partial.tracks = ([200.0, 210, 220].map { ($0, 1) } + [400.0, 410, 420].map { ($0, 3) }).enumerated().map { LocalTrack(index: $0.offset, discNumber: $0.element.1, title: nil, durationSeconds: $0.element.0, url: nil) }
        partial.presentDiscs = [1, 3]; partial.declaredDiscTotal = 3; partial.discCount = 3
        partial.discIDs = [1: "id1", 3: "id3"]
        let p = MatchScorer.score(box, signals: partial, origins: [.discID], fingerprintVote: nil, fingerprintedTracks: 0)
        #expect(p.trackCountMatches == true && p.reasons.contains("Disc IDs match for 2 discs"))
        #expect(p.confidence >= .likely)

        // A plain album keeps the old behaviour: every medium counts.
        var whole = AlbumSignals()
        whole.tracks = (0..<9).map { LocalTrack(index: $0, discNumber: 1, title: nil, durationSeconds: nil, url: nil) }
        #expect(MatchScorer.score(box, signals: whole, origins: [.textSearch], fingerprintVote: nil, fingerprintedTracks: 0).trackCountMatches == true)
    }

    // Live check against Cover Art Archive: COVERCHECK_IMAGE=<the box cover>.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["COVERCHECK_IMAGE"] != nil))
    func coverOfAnotherEditionIsReported() async throws {
        let local = try Data(contentsOf: URL(fileURLWithPath: ProcessInfo.processInfo.environment["COVERCHECK_IMAGE"]!))
        let check = CoverCheck(userAgent: "drtagger-tests/0.1 (prietus@live.com)", discogsToken: nil)
        let single = Candidate(source: .musicbrainz, providerID: "757fed12-3193-4bfb-9f82-5abd962fe769", title: "Vol. 1", artist: "Brautigam")
        let box = Candidate(source: .musicbrainz, providerID: "a4ec848c-d59a-4496-81df-1e1df94d8b91", title: "The Complete Sonatas", artist: "Brautigam")
        let d1 = try #require(await check.distance(local: local, candidate: single))
        let d2 = try #require(await check.distance(local: local, candidate: box))
        print("single \(d1) box \(d2)")
        #expect(d1 >= CoverCheck.differentThreshold)
        #expect(d2 < 0.3)
    }

    @Test func videoDiscOfACDPlusDVDEditionIsIgnored() {
        // Muse, Black Holes and Revelations WPZR-30194: CD (12) + DVD-Video (6).
        let tracks = (1...12).map { CandidateTrack(position: $0, title: "T\($0)", artist: nil, durationMS: 200_000) }
        let c = Candidate(source: .musicbrainz, providerID: "wpzr", title: "Black Holes and Revelations", artist: "Muse",
                          catalogNumber: "WPZR-30194", trackCount: 18, barcode: "4943674070084",
                          media: [CandidateMedium(position: 1, format: "CD", tracks: tracks),
                                  CandidateMedium(position: 2, format: "DVD-Video", trackCount: 6)])
        var s = AlbumSignals()
        s.tracks = (0..<12).map { LocalTrack(index: $0, discNumber: 1, title: nil, durationSeconds: 200, url: nil) }
        let scored = MatchScorer.score(c, signals: s, origins: [.barcode], fingerprintVote: nil, fingerprintedTracks: 0)
        #expect(scored.trackCountMatches == true)
        #expect(c.plausibleTrackCounts.contains(12))
    }

    @Test func clearFingerprintMatchNeedsAGapAndNoContradiction() {
        var signals = AlbumSignals()
        signals.tracks = (0..<8).map { LocalTrack(index: $0, discNumber: 1, title: nil, durationSeconds: 300, url: nil) }
        func scored(_ id: String, _ score: Double, barcode: String? = nil) -> ScoredCandidate {
            ScoredCandidate(candidate: Candidate(source: .musicbrainz, providerID: id, title: "The Berlin Concert", artist: "John Williams", barcode: barcode),
                            score: score, confidence: .likely, reasons: [], origins: [.fingerprint], durationFit: 1,
                            trackCountMatches: true, fingerprintCoverage: 1, formatCompatibility: nil)
        }
        func result(_ c: [ScoredCandidate], _ s: AlbumSignals, fingerprinted: Int = 8) -> IdentificationResult {
            IdentificationResult(signals: s, fingerprints: FingerprintOutcome(fingerprintedTracks: fingerprinted, tracksWithHits: fingerprinted, votes: [], recordingIDs: [:]),
                                 candidates: c, discogsCandidates: [], log: [], startedAt: Date(), elapsedSeconds: 0)
        }
        #expect(result([scored("a", 115)], signals).isClearFingerprintMatch, "the only edition")
        #expect(result([scored("a", 115), scored("b", 90)], signals).isClearFingerprintMatch == false, "another edition within 30 points")
        #expect(result([scored("a", 115)], signals, fingerprinted: 6).isClearFingerprintMatch == false, "two tracks without a fingerprint")
        var coded = signals
        coded.barcodes = [SignalValue("4988031321904", origin: .artwork)]
        #expect(result([scored("a", 115, barcode: "724383608829")], coded).isClearFingerprintMatch == false, "the scanned barcode is another edition's")
    }

    @Test func fingerprintsOutweighReleaseDurations() {
        // Led Zeppelin III, WPCR-13132: MusicBrainz lists every track a few
        // seconds shorter than the rip.
        let c = Self.candidate(tracks: [144, 233, 206, 443, 241, 292, 189, 337, 257, 220], barcode: nil, catno: "WPCR-13132")
        let s = Self.signals(durations: [147.1, 236.4, 211.6, 445.2, 248.6, 298.3, 192.4, 339.2, 258.3, 222.6], catno: "WPCR-13132")
        let all = ReleaseVote(releaseID: c.providerID, trackIndices: Array(0..<10), bestScore: 0.9)
        #expect(MatchScorer.score(c, signals: s, origins: [.fingerprint], fingerprintVote: all, fingerprintedTracks: 10).confidence == .confident)
        let some = ReleaseVote(releaseID: c.providerID, trackIndices: Array(0..<8), bestScore: 0.9)
        #expect(MatchScorer.score(c, signals: s, origins: [.fingerprint], fingerprintVote: some, fingerprintedTracks: 10).confidence == .possible,
                "durations still count when not every track is proven")
    }

    @Test func aCDIsNeverTheSourceOfDSDFiles() {
        let c = Self.candidate(tracks: [200, 180, 240], catno: "W2-25110")
        var s = Self.signals(durations: [200, 180, 240], catno: "W2-25110")
        s.isDSD = true
        let all = ReleaseVote(releaseID: c.providerID, trackIndices: [0, 1, 2], bestScore: 0.9)
        let scored = MatchScorer.score(c, signals: s, origins: [.fingerprint], fingerprintVote: all, fingerprintedTracks: 3)
        #expect(scored.confidence == .possible)
    }

    @Test func oneCatalogNumberEnteredTwiceIsNoRival() {
        // Led Zeppelin II, WPCR-13131: MusicBrainz lists the 2005 and 2008 pressings.
        let a = Self.candidate(tracks: [300, 300], catno: "WPCR-13131"), b = Self.candidate(tracks: [300, 300], catno: "WPCR 13131")
        #expect(MatchScorer.areTwins(a, b))
        #expect(!MatchScorer.areTwins(a, Self.candidate(tracks: [300, 300], catno: "AMCY-4006")))
    }

    @Test func theAlbumsCoverBreaksATieBetweenProvenEditions() {
        var signals = AlbumSignals()
        signals.tracks = (0..<8).map { LocalTrack(index: $0, discNumber: 1, title: nil, durationSeconds: 300, url: nil) }
        func scored(_ id: String, _ catno: String) -> ScoredCandidate {
            ScoredCandidate(candidate: Candidate(source: .musicbrainz, providerID: id, title: "Burn", artist: "Deep Purple", catalogNumber: catno),
                            score: 90, confidence: .likely, reasons: [], origins: [.fingerprint], durationFit: 1,
                            trackCountMatches: true, fingerprintCoverage: 1, formatCompatibility: nil)
        }
        let result = IdentificationResult(signals: signals, fingerprints: FingerprintOutcome(fingerprintedTracks: 8, tracksWithHits: 8, votes: [], recordingIDs: [:]),
                                          candidates: [scored("jp", "WPCR-13115"), scored("uk", "CDP 7 92611 2")], discogsCandidates: [], log: [], startedAt: Date(), elapsedSeconds: 0)
        let (jp, uk) = (result.candidates[0].id, result.candidates[1].id)
        #expect(result.coverTieBreak(distances: [jp: 0.9, uk: 0.2])?.id == uk)
        #expect(result.coverTieBreak(distances: [jp: 0.2, uk: 0.5]) == nil, "both covers look alike")
        #expect(result.coverTieBreak(distances: [:]) == nil, "no images")
    }

    @Test func unofficialSACDIsTaggedAsTheAlbum() {
        var signals = AlbumSignals()
        signals.tracks = (0..<8).map { LocalTrack(index: $0, discNumber: 1, title: nil, durationSeconds: 300, url: nil) }
        signals.isDSD = true
        func scored(_ id: String, group: String, format: String, score: Double = 75) -> ScoredCandidate {
            ScoredCandidate(candidate: Candidate(source: .musicbrainz, providerID: id, releaseGroupID: group, title: "Burn", artist: "Deep Purple", mediaFormat: format),
                            score: score, confidence: .possible, reasons: [], origins: [.fingerprint], durationFit: 0.5,
                            trackCountMatches: true, fingerprintCoverage: 1, formatCompatibility: .unlikely)
        }
        func result(_ c: [ScoredCandidate]) -> IdentificationResult {
            IdentificationResult(signals: signals, fingerprints: FingerprintOutcome(fingerprintedTracks: 8, tracksWithHits: 8, votes: [], recordingIDs: [:]),
                                 candidates: c, discogsCandidates: [], log: [], startedAt: Date(), elapsedSeconds: 0)
        }
        #expect(result([scored("lp", group: "burn", format: "12\" Vinyl"), scored("cd", group: "burn", format: "CD")]).albumOnlyPick?.candidate.providerID == "cd",
                "CD numbering over vinyl sides")
        #expect(result([scored("cd", group: "burn", format: "CD"), scored("best-of", group: "hits", format: "CD")]).albumOnlyPick == nil,
                "the same recordings on another album: which one is unclear")
        #expect(result([scored("cd", group: "burn", format: "CD"), scored("sacd", group: "burn", format: "SACD", score: 40)]).albumOnlyPick == nil,
                "a SACD edition is known: pick it, not the album")
    }

    @Test func printedWordsAreNotCatalogs() {
        let found = CatalogNumberParser.extract(from: ["EUROPE-2006", "MADE IN JAPAN 2006", "WPZR-30194", "RECORDED IN 1969",
                                                       "HOLLYWOOD, CA 90068", "FOR 1954", "THIS 2011"]).map(\.formatted)
        #expect(found == ["WPZR-30194"])
    }

    @Test func scansContradictingTheTaggedEdition() {
        // Muse, Black Holes and Revelations: files tagged with WPCR-12306,
        // scans and folder say WPZR-30194 (the CD+DVD edition).
        let tagged = Candidate(source: .musicbrainz, providerID: "wpcr", title: "Black Holes and Revelations", artist: "Muse",
                               catalogNumber: "WPCR-12306", barcode: "4943674064373")
        var s = AlbumSignals()
        s.barcodes = [SignalValue("4943674070084", origin: .artwork)]
        s.catalogNumbers = [SignalValue("WPZR-30194", origin: .folderName)]
        #expect(MatchScorer.contradictsLocalCodes(tagged, signals: s))
        let right = Candidate(source: .musicbrainz, providerID: "wpzr", title: "Black Holes and Revelations", artist: "Muse",
                              catalogNumber: "WPZR-30194~5", barcode: "4943674070084")
        #expect(!MatchScorer.contradictsLocalCodes(right, signals: s))
        #expect(!MatchScorer.contradictsLocalCodes(tagged, signals: AlbumSignals()), "no codes: nothing to contradict")
    }

    @Test func numericCatalogIsABarcode() {
        var s = AlbumSignals()
        s.catalogNumbers = [SignalValue("4988006888883", origin: .sacdText), SignalValue("TOGE-12061", origin: .sacdText)]
        #expect(s.uniqueBarcodes == ["4988006888883"])
        #expect(s.uniqueCatalogNumbers == ["TOGE-12061"])
    }

    @Test func normalisation() {
        #expect(MatchScorer.normalize("The Rolling Stones") == "rolling stones")
        #expect(MatchScorer.normalize("Leño – ¡Corre, corre!") == "leno corre corre")
        #expect(MatchScorer.similar("Walkin'", "Walkin’"))
        #expect(MatchScorer.barcodesEqual("035628388926", "0035628388926"))
        #expect(!MatchScorer.barcodesEqual("035628388926", "035628388927"))
    }

    @Test func consensusFilterDropsCompilations() {
        let votes = FingerprintService.consensus(
            scores: ["album": 0.9, "compilation": 0.95, "single": 0.7],
            trackHits: ["album": [0, 1, 2, 3, 4, 5, 6, 7], "compilation": [2, 5], "single": [0]],
            trackCount: 8
        )
        #expect(votes.map(\.releaseID) == ["album"])
        let sparse = FingerprintService.consensus(scores: ["a": 0.9, "b": 0.8], trackHits: ["a": [0], "b": [1]], trackCount: 2)
        #expect(sparse.count == 2)
    }
}

@Suite("Real samples", .serialized)
struct RealSampleTests {

    @Test func scansBarcodeFromBackCover() async throws {
        let back = TestEnv.samples.appending(path: "cue/1974 - Diamond Dogs (1984, W. Germany, RCA PD83889)/Scans/Back.png")
        guard FileManager.default.fileExists(atPath: back.path) else { return }
        let result = try await ArtworkScanner().scan(back)
        #expect(!result.barcodes.isEmpty, "back cover should carry an EAN/UPC; texts: \(result.recognizedTexts.prefix(8))")
        for code in result.barcodes { #expect(code.count == 12 || code.count == 13 || code.count == 8) }
        #expect(result.catalogNumbers.contains { $0.contains("83889") }, "catalog PD 83889 expected; got \(result.catalogNumbers)")
    }

    @Test func collectsSignalsFromSplitFolder() async throws {
        guard let tool = TestEnv.ffmpeg, let album = TestEnv.album("cue/1974 - Diamond Dogs (1984, W. Germany, RCA PD83889)") else { return }
        var options = SignalCollector.Options()
        options.scanArtwork = false
        let s = await SignalCollector(tool: tool).collect(album: album, options: options)
        #expect(s.trackCount == 8)
        #expect(s.tracks.allSatisfy { ($0.durationSeconds ?? 0) > 60 })
        #expect(s.albumHint?.lowercased().contains("diamond dogs") == true)
        #expect(s.artistHint?.lowercased().contains("bowie") == true)
        #expect(s.yearHint?.count == 4)
        #expect(!s.existingTags.isEmpty)
    }

    @Test func collectsSignalsFromCueImageWithTOC() async throws {
        guard let tool = TestEnv.ffmpeg, let album = TestEnv.album("cue-images/Miles Davis All Stars - Walkin' XRCD") else { return }
        let cue = try #require(album.discs.first?.cue)
        let toc = try DiscTOC(cue: cue, fileFrames: [170557])
        var options = SignalCollector.Options()
        options.scanArtwork = false
        let s = await SignalCollector(tool: tool).collect(album: album, toc: toc, options: options)
        #expect(s.discID == "iOSL4j4VX_YutvVxL4QjWVsVEJE-")
        #expect(s.tracks.count == 5)
        #expect(abs((s.tracks[0].durationSeconds ?? 0) - Double(60712 - 37) / 75) < 0.01)
        #expect(s.tracks[0].imageStart == 37.0 / 75)
    }

    // Network: identify the XRCD image from its TOC. DRTAGGER_NETWORK_TESTS=1
    // (and DRTAGGER_ACOUSTID_KEY for fingerprints).
    @Test func identifiesWalkinFromTOC() async throws {
        guard TestEnv.network, let tool = TestEnv.ffmpeg, let album = TestEnv.album("cue-images/Miles Davis All Stars - Walkin' XRCD") else { return }
        let cue = try #require(album.discs.first?.cue)
        let toc = try DiscTOC(cue: cue, fileFrames: [170557])
        var config = IdentifierConfig(userAgent: TestEnv.ua, acoustIDKey: TestEnv.acoustIDKey)
        config.scanArtwork = false
        let result = await Identifier(config: config, tool: tool).identify(album: album, toc: toc)
        print(result.log.joined(separator: "\n"))
        let best = try #require(result.best)
        #expect(best.candidate.title.lowercased().contains("walkin"))
        #expect(best.candidate.allTracks.count == 5)
        #expect(best.confidence >= .likely)
        #expect(best.durationFit ?? 0 > 0.8)
    }

    // Network: a SACD ISO identified from its disc text alone (catalog
    // "CAPP139 SA" spelled "CAPP 139 SA" on MusicBrainz, hybrid layers).
    @Test func identifiesAjaSACDFromCatalog() async throws {
        let iso = URL(fileURLWithPath: NSString(string: "~/Downloads/1977 - Steely Dan - Aja.iso").expandingTildeInPath)
        guard TestEnv.network, let tool = TestEnv.ffmpeg, FileManager.default.fileExists(atPath: iso.path),
              let album = LibraryScanner().scan([iso]).albums.first else { return }
        var config = IdentifierConfig(userAgent: TestEnv.ua)
        config.useFingerprints = false
        let result = await Identifier(config: config, tool: tool).identify(album: album)
        print(result.log.joined(separator: "\n"))
        let best = try #require(result.best)
        #expect(best.candidate.catalogNumbers.contains { CatalogNumberParser.normalize($0) == "CAPP139SA" }, "best: \(best.candidate.catalogNumber ?? "?")")
        #expect(best.candidate.mediaFormat?.lowercased().contains("sacd") == true)
        #expect(best.confidence >= .likely)
        #expect(best.trackCountMatches == true)
    }

    // Network: an empty, untagged folder identified from its name alone.
    @Test func identifiesMeteoraEditionFromFolderName() async throws {
        guard TestEnv.network, let tool = TestEnv.ffmpeg else { return }
        let folder = FileManager.default.temporaryDirectory.appending(path: "Linkin Park - 2003 - Meteora 20th Anniversary Edition (MQA)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let album = DetectedAlbum(url: folder, kind: .trackFolder, discs: [DetectedDisc(number: 1, folder: folder)])
        var config = IdentifierConfig(userAgent: TestEnv.ua)
        config.useFingerprints = false
        config.scanArtwork = false
        let result = await Identifier(config: config, tool: tool).identify(album: album)
        print(result.log.joined(separator: "\n"))
        let best = try #require(result.best)
        #expect(best.candidate.title.lowercased().contains("anniversary"), "best: \(best.candidate.title)")
        #expect(best.candidate.mediaFormat?.lowercased().contains("digital") == true, "best: \(best.candidate.mediaFormat ?? "?")")
    }

    // Network: split folder with tags, scans and (optionally) fingerprints.
    @Test func identifiesDiamondDogsFromTagsAndScans() async throws {
        guard TestEnv.network, let tool = TestEnv.ffmpeg, let album = TestEnv.album("cue/1974 - Diamond Dogs (1984, W. Germany, RCA PD83889)") else { return }
        let config = IdentifierConfig(userAgent: TestEnv.ua, acoustIDKey: TestEnv.acoustIDKey)
        let result = await Identifier(config: config, tool: tool).identify(album: album)
        print(result.log.joined(separator: "\n"))
        let best = try #require(result.best)
        #expect(best.candidate.title.lowercased().contains("diamond dogs"))
        #expect(best.candidate.artist.lowercased().contains("bowie"))
        #expect(best.candidate.allTracks.count == 8)
        #expect(best.confidence >= .likely)
    }
}

@Suite("CDDB responder") struct CDDBResponderTests {
    static func candidate(_ id: String, title: String, durations: [Int], year: String, artist: String = "坂本龍一") -> Candidate {
        let tracks = durations.enumerated().map { CandidateTrack(position: $0.offset + 1, title: "Track \($0.offset + 1) 曲", durationMS: $0.element * 1000) }
        return Candidate(source: .musicbrainz, providerID: id, title: title, artist: artist, year: year, country: "JP", label: "Midi",
                         catalogNumber: "MDCL-1234", mediaFormat: "CD", trackCount: tracks.count, tracks: tracks, barcode: "4988000000000",
                         media: [CandidateMedium(position: 1, format: "CD", tracks: tracks)])
    }

    @Test func queryListsRankedMatchesAndReadReturnsXmcd() async {
        // Three tracks of 200, 180 and 240 s: offsets 150, 15150, 28650; length (150+46500)/75 = 622 s.
        let good = Self.candidate("good", title: "音楽図鑑", durations: [200, 180, 240], year: "1984")
        let poor = Self.candidate("poor", title: "音楽図鑑 (remaster)", durations: [205, 170, 250], year: "2015")
        let wrongCount = Self.candidate("other", title: "Other", durations: [100, 100], year: "2000")
        let responder = CDDBResponder { toc in
            #expect(toc.trackOffsets == [150, 15150, 28650] && toc.leadOut == 622 * 75)
            return [poor, wrongCount, good]
        }
        let q = await responder.respond(toQuery: "cmd=cddb+query+2a024903+3+150+15150+28650+622&hello=user+host+XLD+20250302&proto=6")
        let lines = q.split(separator: "\n").map(String.init)
        #expect(lines.first?.hasPrefix("211 ") == true, "\(q)")
        #expect(lines[1] == "rock 2a024903 坂本龍一 / 音楽図鑑 [1984 · JP · CD · MDCL-1234]", "best fit first: \(lines[1])")
        #expect(lines[2].hasPrefix("misc 2a024903 ") && lines.last == ".")
        #expect(!q.contains("Other"), "a release with another track count is not listed")

        let r = await responder.respond(toQuery: "cmd=cddb+read+rock+2a024903&hello=user+host+XLD+20250302&proto=6")
        #expect(r.hasPrefix("210 rock 2a024903 "))
        #expect(r.contains("DTITLE=坂本龍一 / 音楽図鑑\n") && r.contains("DYEAR=1984\n") && r.contains("TTITLE2=Track 3 曲\n"))
        #expect(r.contains("#\t15150\n") && r.contains("# Disc length: 622 seconds"))
        #expect(r.contains("MDCL-1234") && r.contains("MusicBrainz release good"))
        #expect(r.hasSuffix("PLAYORDER=\n.\n"))

        #expect(await responder.respond(toQuery: "cmd=cddb+read+jazz+2a024903").hasPrefix("401 "))
        #expect(await responder.respond(toQuery: "cmd=proto+6").hasPrefix("201 "))
        let none = CDDBResponder { _ in [] }
        #expect(await none.respond(toQuery: "cmd=cddb+query+00000001+1+150+60").hasPrefix("202 "))
        #expect(await none.respond(toQuery: "cmd=cddb+query+bad").hasPrefix("500 "))
    }

    @Test func singleMatchAnswers200AndLongFieldsSplit() async {
        let one = Self.candidate("one", title: "A", durations: [200, 180, 240], year: "1984")
        let responder = CDDBResponder { _ in [one] }
        let q = await responder.respond(toQuery: "cmd=cddb+query+2a024903+3+150+15150+28650+622")
        #expect(q == "200 rock 2a024903 坂本龍一 / A\n")
        let long = CDDBResponder.field("TTITLE0", String(repeating: "あ", count: 120))
        #expect(long.split(separator: "\n").count == 2 && long.split(separator: "\n").allSatisfy { $0.utf8.count <= 256 })
    }

    // Network: the Walkin' XRCD TOC through the real MusicBrainz fuzzy lookup.
    @Test func liveFuzzyTOCLookup() async throws {
        guard TestEnv.network, let album = TestEnv.album("cue-images/Miles Davis All Stars - Walkin' XRCD"), let cue = album.discs.first?.cue else { return }
        let toc = try DiscTOC(cue: cue, fileFrames: [170557])
        let q = "cmd=cddb+query+\(toc.freeDBDiscID)+\(toc.trackOffsets.count)+" + toc.trackOffsets.map(String.init).joined(separator: "+") + "+\(toc.leadOut / 75)&proto=6"
        let answer = await CDDBResponder(userAgent: TestEnv.ua).respond(toQuery: q)
        print(answer)
        #expect(answer.hasPrefix("200 ") || answer.hasPrefix("211 "))
        #expect(answer.lowercased().contains("walkin"))
    }
}
