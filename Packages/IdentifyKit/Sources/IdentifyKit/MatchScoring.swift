import Foundation
import ProviderKit

public enum MatchConfidence: String, Sendable, Codable, Comparable {
    case unlikely
    case possible
    case likely
    case confident

    private var rank: Int {
        switch self {
        case .unlikely: return 0
        case .possible: return 1
        case .likely: return 2
        case .confident: return 3
        }
    }

    public static func < (lhs: MatchConfidence, rhs: MatchConfidence) -> Bool { lhs.rank < rhs.rank }
}

// How a candidate reached the pool; strong origins count as independent
// evidence when they agree.
public enum CandidateOrigin: String, Sendable, Codable, Hashable {
    case tagMBID
    case ctdbMBID
    case discID
    case tocMatch
    case barcode
    case catalogNumber
    case fingerprint
    case releaseGroup
    case textSearch

    var isStrong: Bool {
        switch self {
        case .tagMBID, .discID, .tocMatch, .barcode, .catalogNumber, .fingerprint: return true
        case .ctdbMBID, .releaseGroup, .textSearch: return false
        }
    }
}

// Whether a candidate's medium could physically be the origin of the local
// files. `unknown` covers releases MusicBrainz lists without a format, which
// is common; only `unlikely` gets folded away in the UI.
public enum FormatCompatibility: String, Sendable, Codable, Hashable {
    case fits
    case unknown
    case unlikely
}

public struct ScoredCandidate: Sendable, Codable, Hashable, Identifiable {
    public let candidate: Candidate
    public let score: Double
    public let confidence: MatchConfidence
    public let reasons: [String]
    public let origins: [CandidateOrigin]
    public let durationFit: Double?        // 0…1, nil when unknown
    public let trackCountMatches: Bool?
    public let fingerprintCoverage: Double?
    public let formatCompatibility: FormatCompatibility?   // nil in results saved before it existed

    public var id: String { candidate.id }
}

public enum MatchScorer {

    // Tolerances: a few seconds per track absorbs pregap conventions and
    // the ±2 s MusicBrainz commonly disagrees with rips by.
    static let perTrackToleranceSeconds = 4.0

    public static func score(
        _ candidate: Candidate,
        signals: AlbumSignals,
        origins: [CandidateOrigin],
        fingerprintVote: ReleaseVote?,
        fingerprintedTracks: Int
    ) -> ScoredCandidate {
        var score = 0.0
        var reasons: [String] = []
        var strong = 0

        // Media: a hybrid SACD is listed as two "layers" of one disc; only the
        // layer the local files can come from counts.
        let media = relevantMedia(candidate, localFormat: signals.localFormat)
        let candidateTracks = media.isEmpty ? candidate.tracks : media.flatMap(\.tracks)

        // Format plausibility.
        let formatText = (media.compactMap(\.format) + [candidate.mediaFormat ?? ""]).joined(separator: " ").lowercased()
        let isSACD = formatText.contains("sacd") || formatText.contains("dsd")
        let isVinyl = formatText.contains("vinyl") || formatText.contains("cassette") || formatText.contains("shellac") || formatText.contains("reel")
        let isCD = formatText.contains("cd") && !(formatText.contains("sacd") && !formatText.contains("cd layer") && !formatText.contains("hybrid"))
        switch signals.localFormat {
        case .sacd:
            if isSACD { score += 15; reasons.append("SACD edition") }
            else if isVinyl || formatText.contains("digital") || formatText.contains("dvd") || formatText.contains("blu-ray") { score -= 20; reasons.append("Not a SACD (\(candidate.mediaFormat ?? "unknown format"))") }
            else if !formatText.isEmpty { score -= 5 }
        case .cd:
            if isVinyl { score -= 20; reasons.append("Vinyl cannot be the source of a CD rip") }
            else if isCD { score += 8; reasons.append("CD edition") }
            else if isSACD { score -= 10; reasons.append("SACD without a CD layer") }
        case .hiRes, .unknown:
            break
        }

        // Medium named in the folder or tags ("XRCD Japan", "Vinyl Rip",
        // "MQA"): weaker than the files' own format, so it only nudges.
        if let hint = signals.sourceHint {
            let isDigital = formatText.contains("digital")
            let isDVD = formatText.contains("dvd") || formatText.contains("blu-ray")
            switch hint {
            case .vinyl:
                if isVinyl { score += 12; reasons.append("Vinyl, as the folder says") }
                else if signals.localFormat != .cd, !formatText.isEmpty { score -= 6 }
            case .sacd:
                if isSACD, signals.localFormat != .sacd { score += 10; reasons.append("SACD, as the folder says") }
            case .cd:
                if isCD, signals.localFormat != .cd { score += 6; reasons.append("CD, as the folder says") }
            case .digital:
                if isDigital { score += 8; reasons.append("Digital release, as the folder says") }
                else if isVinyl || isDVD { score -= 6 }
            case .dvd:
                if isDVD { score += 10; reasons.append("DVD/Blu-ray, as the folder says") }
            }
        }

        // Track count: total and, for multi-disc albums, per medium.
        let localCount = signals.trackCount
        let candidateCount = candidateTracks.isEmpty ? candidate.trackCount : candidateTracks.count
        var trackCountMatches: Bool? = nil
        if localCount > 0, let candidateCount {
            trackCountMatches = candidateCount == localCount
            if candidateCount == localCount {
                score += 10
                reasons.append("Track count \(localCount) matches")
            } else {
                score -= 40
                reasons.append("Track count differs (\(candidateCount) vs \(localCount))")
            }
        }
        if signals.discCount > 1, !media.isEmpty {
            if media.count == signals.discCount { score += 5; reasons.append("\(signals.discCount) discs") }
            else { score -= 15; reasons.append("Disc count differs (\(media.count) vs \(signals.discCount))") }
        }

        // Durations.
        var durationFit: Double? = nil
        let localDurations = signals.tracks.compactMap(\.durationSeconds)
        let candDurations = candidateTracks.map { $0.durationMS.map { Double($0) / 1000 } }
        if localDurations.count == signals.tracks.count, candDurations.count == localDurations.count, !localDurations.isEmpty,
           candDurations.allSatisfy({ $0 != nil }) {
            let diffs = zip(localDurations, candDurations.compactMap { $0 }).map { abs($0 - $1) }
            let mean = diffs.reduce(0, +) / Double(diffs.count)
            let fit = max(0, 1 - mean / (perTrackToleranceSeconds * 2))
            durationFit = fit
            score += 30 * fit
            reasons.append(String(format: "Durations differ by %.1f s on average", mean))
            if mean > perTrackToleranceSeconds * 3 { score -= 30 }
        }

        // Strong signals.
        if let barcode = candidate.barcode?.filter(\.isNumber), !barcode.isEmpty,
           signals.uniqueBarcodes.contains(where: { Self.barcodesEqual($0, barcode) }) {
            score += 40; strong += 1
            reasons.append("Barcode \(barcode) matches")
        }
        let candCatalogs = candidate.catalogNumbers.map(CatalogNumberParser.normalize)
        if let hit = signals.uniqueCatalogNumbers.first(where: { local in
            let n = CatalogNumberParser.normalize(local)
            return !n.isEmpty && candCatalogs.contains { $0 == n || (n.count >= 6 && ($0.hasSuffix(n) || n.hasSuffix($0))) }
        }) {
            score += 30; strong += 1
            reasons.append("Catalog number \(hit) matches")
        }
        if let discID = signals.discID, candidate.allDiscIDs.contains(discID) {
            score += 45; strong += 1
            reasons.append("Disc ID matches")
        } else if origins.contains(.tocMatch) {
            score += 25; strong += 1
            reasons.append("CD TOC matches (MusicBrainz)")
        }
        if origins.contains(.tagMBID) {
            score += 45; strong += 1
            reasons.append("Release MBID from the file tags")
        } else if origins.contains(.ctdbMBID) {
            score += 15
            reasons.append("CUETools DB lists this release for the TOC")
        }
        var coverage: Double? = nil
        if let vote = fingerprintVote, fingerprintedTracks > 0 {
            let c = Double(vote.hitCount) / Double(fingerprintedTracks)
            coverage = c
            if c >= 0.8 { score += 35; strong += 1 }
            else if c >= 0.5 { score += 20 }
            else { score += 8 }
            reasons.append("Fingerprints match \(vote.hitCount) of \(fingerprintedTracks) tracks")
        }

        // Soft text signals.
        if let a = signals.artistHint, similar(a, candidate.artist) { score += 10; reasons.append("Artist matches") }
        if let t = signals.albumHint, similar(t, candidate.title) { score += 10; reasons.append("Title matches") }
        // Edition words ("20th Anniversary", "Deluxe", "Remaster") against the
        // candidate's title and disambiguation.
        let candidateWords = Set(normalize(candidate.title + " " + (candidate.disambiguation ?? "")).split(separator: " ").map(String.init))
        if let e = signals.editionHint {
            let keywords = editionKeywords(e)
            if !keywords.isEmpty {
                if keywords.allSatisfy({ k in candidateWords.contains { $0.hasPrefix(k) } }) {
                    score += 10; reasons.append("Edition \"\(e)\" matches")
                } else {
                    score -= 5; reasons.append("Edition \"\(e)\" not mentioned")
                }
            }
        }
        // Years: the pressing year pins an edition; the original year is
        // weaker when the folder names an edition.
        if let ey = signals.editionYearHint, ey == candidate.year {
            score += 8; reasons.append("Edition year \(ey)")
        } else if let y = signals.yearHint, y == candidate.year {
            let weak = signals.editionHint != nil || signals.editionYearHint != nil
            score += weak ? 2 : 5; reasons.append("Year \(y)")
        }
        if let c = signals.countryHint, let cc = candidate.country, c == cc { score += 6; reasons.append("Country \(c) matches") }
        if candidate.status == "Bootleg" { score -= 10 }

        let fitOK = durationFit == nil ? (trackCountMatches ?? true) : durationFit! >= 0.6
        let confidence: MatchConfidence
        if strong >= 2 && fitOK && (trackCountMatches ?? true) { confidence = .confident }
        else if strong >= 1 && fitOK && (trackCountMatches ?? true) { confidence = .likely }
        else if score >= 20 { confidence = .possible }
        else { confidence = .unlikely }

        return ScoredCandidate(
            candidate: candidate, score: score, confidence: confidence, reasons: reasons,
            origins: origins, durationFit: durationFit, trackCountMatches: trackCountMatches,
            fingerprintCoverage: coverage, formatCompatibility: formatCompatibility(candidate, signals: signals)
        )
    }

    // Could this release's media be where the local files came from?
    // A medium named in the folder or tags wins over what the files imply.
    public static func formatCompatibility(_ candidate: Candidate, signals: AlbumSignals) -> FormatCompatibility {
        let formats = (candidate.media.compactMap(\.format) + [candidate.mediaFormat ?? ""] + candidate.formatDescriptions)
            .map { $0.lowercased() }
            .filter { !$0.isEmpty && $0 != "unknown" && $0 != "(unknown)" && $0 != "other" }
        guard !formats.isEmpty else { return .unknown }
        let text = formats.joined(separator: " ")
        let hasSACD = text.contains("sacd") || text.contains("dsd")
        let hasCDLayer = formats.contains { f in
            (f.contains("cd") && !f.contains("sacd")) || f.contains("cd layer") || f.contains("hybrid") || f.contains("hdcd") || f.contains("shm-cd")
        }
        let hasDigital = text.contains("digital") || text.contains("file") || text.contains("download")
        let hasVinyl = text.contains("vinyl") || text.contains("lp") || text.contains("flexi") || text.contains("acetate")
        let hasDVD = text.contains("dvd") || text.contains("blu-ray") || text.contains("bluray") || text.contains("hd dvd")
        let hasAnalogTape = text.contains("cassette") || text.contains("reel") || text.contains("8-track") || text.contains("shellac")
        let hasTypeInfo = hasSACD || hasCDLayer || hasDigital || hasVinyl || hasDVD || hasAnalogTape
        guard hasTypeInfo else { return .unknown }   // "Box set", "CD-ROM"-style labels say nothing usable

        // 1. Explicit hint: the user wrote what it is.
        if let hint = signals.sourceHint {
            switch hint {
            case .vinyl: return hasVinyl ? .fits : .unlikely
            case .sacd: return hasSACD ? .fits : .unlikely
            case .dvd: return hasDVD ? .fits : .unlikely
            case .digital: return hasDigital || (signals.isSACDImage && hasSACD) ? .fits : .unlikely
            case .cd: return hasCDLayer ? .fits : .unlikely
            }
        }
        // 2. What the files themselves allow.
        switch signals.localFormat {
        case .sacd:
            if hasSACD { return .fits }
            // Loose DSF files may be a DSD download; an ISO can only be a disc.
            if !signals.isSACDImage && hasDigital { return .fits }
            return .unlikely
        case .cd:
            if hasCDLayer || hasDigital { return .fits }
            return .unlikely
        case .hiRes:
            if hasDigital || hasVinyl || hasSACD || hasDVD { return .fits }
            return .unlikely                             // a plain CD or tape cannot yield 24-bit / >44.1 kHz
        case .unknown:
            return .unknown
        }
    }

    // Hybrid SACDs (and CD+DVD sets) list one medium per layer; pick the
    // layer matching the local files, otherwise keep every medium.
    public static func relevantMedia(_ candidate: Candidate, localFormat: AlbumSignals.LocalFormat) -> [CandidateMedium] {
        let media = candidate.media
        let layers = media.filter { ($0.format ?? "").lowercased().contains("layer") }
        guard !layers.isEmpty else { return media }
        let wanted: (String) -> Bool
        switch localFormat {
        case .sacd: wanted = { $0.contains("sacd layer") }
        case .cd: wanted = { $0.contains("cd layer") && !$0.contains("sacd layer") }
        default: wanted = { _ in false }
        }
        let others = media.filter { !($0.format ?? "").lowercased().contains("layer") }
        if let chosen = layers.first(where: { wanted(($0.format ?? "").lowercased()) }) {
            return others + [chosen]
        }
        return others + [layers[0]]
    }

    // "20th Anniversary Edition" → ["20th", "anniversary"]; "Remastered" → ["remaster"].
    static func editionKeywords(_ edition: String) -> [String] {
        let generic: Set<String> = ["edition", "version", "the", "of", "and", "release", "import", "press", "pressing"]
        return normalize(edition).split(separator: " ").map(String.init).filter { !generic.contains($0) }.map { w in
            w.hasSuffix("ed") && w.count > 5 ? String(w.dropLast(2)) : w
        }
    }

    static func barcodesEqual(_ a: String, _ b: String) -> Bool {
        let x = a.filter(\.isNumber), y = b.filter(\.isNumber)
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x == y { return true }
        // UPC-A vs EAN-13 with a leading zero.
        return x.drop { $0 == "0" } == y.drop { $0 == "0" }
    }

    // Case, diacritics and punctuation insensitive; "The X" == "X".
    public static func normalize(_ s: String) -> String {
        var t = s.lowercased().folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        t = t.replacingOccurrences(of: "&", with: "and")
        t = t.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }.map(String.init).joined()
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("the ") { t.removeFirst(4) }
        return t
    }

    static func similar(_ a: String, _ b: String) -> Bool {
        let x = normalize(a), y = normalize(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x == y { return true }
        if x.count >= 6 && (x.contains(y) || y.contains(x)) { return true }
        return false
    }
}
