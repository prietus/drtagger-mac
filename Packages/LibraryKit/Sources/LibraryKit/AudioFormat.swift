import Foundation

// Lossless audio containers the app understands. Detection here is by file
// extension only; codec verification (an .m4a that is really AAC) happens
// later with ffprobe.
public enum AudioFormat: String, CaseIterable, Sendable, Codable, Hashable {
    case flac
    case ape
    case wavpack
    case tta
    case wav
    case aiff
    case alac
    case dsf
    case dff

    public static func from(url: URL) -> AudioFormat? {
        from(extension: url.pathExtension)
    }

    public static func from(extension ext: String) -> AudioFormat? {
        switch ext.lowercased() {
        case "flac": return .flac
        case "ape": return .ape
        case "wv": return .wavpack
        case "tta": return .tta
        case "wav", "wave": return .wav
        case "aiff", "aif", "aifc": return .aiff
        case "m4a": return .alac
        case "dsf": return .dsf
        case "dff": return .dff
        default: return nil
        }
    }

    public var isDSD: Bool { self == .dsf || self == .dff }

    public var displayName: String {
        switch self {
        case .flac: return "FLAC"
        case .ape: return "Monkey's Audio"
        case .wavpack: return "WavPack"
        case .tta: return "TTA"
        case .wav: return "WAV"
        case .aiff: return "AIFF"
        case .alac: return "ALAC"
        case .dsf: return "DSF"
        case .dff: return "DFF"
        }
    }
}

// File-name rules shared by the scanner.
public enum FileRules {

    public static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "bmp", "tif", "tiff", "webp", "heic",
    ]

    // Folder names that hold scans rather than audio. They are not skipped
    // (artwork inside them is collected) but never form an album.
    public static let artworkFolderNames: Set<String> = [
        "scans", "scan", "artwork", "art", "covers", "cover", "booklet", "images", "pics",
    ]

    // AppleDouble resource forks, Finder metadata, Synology/QNAP index
    // folders and our own NAS markers.
    public static func isJunk(name: String) -> Bool {
        if name.hasPrefix("._") || name.hasPrefix(".") { return true }
        let lower = name.lowercased()
        if lower == "thumbs.db" || lower == "desktop.ini" || lower == "@eadir" { return true }
        if lower.hasSuffix(".dr_done") || lower.hasSuffix(".part") || lower.hasSuffix(".tmp") { return true }
        return false
    }

    public static func isAudio(_ url: URL) -> Bool {
        AudioFormat.from(url: url) != nil
    }

    public static func isArtwork(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    public static func isCue(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "cue"
    }

    public static func isISO(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "iso"
    }

    public static func isLog(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "log" || ext == "accurip" || ext == "txt" || ext == "m3u" || ext == "m3u8"
    }

    // Raw CD images referenced by a CUE (FILE "x.bin" BINARY).
    public static func isRawImage(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "bin" || ext == "img" || ext == "iso"
    }

    // "CD1", "Disc 2", "Disco 3 - Live", "disk_4" … Returns the disc number.
    // "Box Set (Disc 2).cue", "Cancioneros (disc 1-3).iso", "CD2", "Disc 2 of 4":
    // the disc number anywhere in a file or folder name, with the total when
    // the name states it. Volumes are not discs ("Cantatas Vol. 40" is an album).
    private static let discTokenPattern = try! NSRegularExpression(
        pattern: #"(?:^|[\s\(\[_\-.])(?:cd|disc|disco|disk|dvd)\s*[-_.#]?\s*(\d{1,2})(?:\s*(?:of|de|-|/)\s*(\d{1,2}))?(?=$|[\s\)\]_\-.,])"#,
        options: [.caseInsensitive])

    public static func discNumber(fromFileName name: String) -> (number: Int, total: Int?)? {
        let base = (name as NSString).deletingPathExtension
        let range = NSRange(base.startIndex..., in: base)
        guard let m = discTokenPattern.firstMatch(in: base, range: range), let n = Range(m.range(at: 1), in: base), let number = Int(base[n]) else { return nil }
        let total = Range(m.range(at: 2), in: base).flatMap { Int(base[$0]) }
        return (number, total)
    }

    // The name without its disc token, so siblings of one set compare equal:
    // "Led Zeppelin - Box Set (Disc 2)" → "Led Zeppelin - Box Set".
    public static func strippingDiscToken(_ name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        let range = NSRange(base.startIndex..., in: base)
        guard let m = discTokenPattern.firstMatch(in: base, range: range), var r = Range(m.range, in: base) else { return base }
        var t = base
        // The token's own brackets go with it: "(Disc 2)" → "".
        if let first = base[r].first, first == "(" || first == "[" {
            var end = r.upperBound
            while end < base.endIndex, base[end] == " " { end = base.index(after: end) }
            if end < base.endIndex, base[end] == ")" || base[end] == "]" { r = r.lowerBound..<base.index(after: end) }
        }
        t.removeSubrange(r)
        t = t.replacingOccurrences(of: #"\(\s*\)|\[\s*\]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-_.,")))
    }

    public static func discNumber(fromFolderName name: String) -> Int? {
        let pattern = #"^(?:cd|disc|disco|disk|dvd)\s*[-_.#]?\s*(\d{1,2})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(name.startIndex..., in: name)
        guard let match = regex.firstMatch(in: name, range: range),
              let numRange = Range(match.range(at: 1), in: name) else { return nil }
        return Int(name[numRange])
    }
}

extension Array where Element == URL {
    // Finder-like ordering: "2 - b" before "10 - a".
    public func naturallySorted() -> [URL] {
        sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
