import Foundation

// A position on a CD in 1/75 s frames, as CUE sheets express it (mm:ss:ff).
public struct CueTime: Sendable, Equatable, Hashable, Codable, Comparable {
    public static let framesPerSecond = 75

    public let frames: Int

    public init(frames: Int) {
        self.frames = frames
    }

    // "mm:ss:ff" — minutes may exceed 99 on long images.
    public init?(msf: String) {
        let parts = msf.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let m = Int(parts[0]), let s = Int(parts[1]), let f = Int(parts[2]),
              m >= 0, (0..<60).contains(s), (0..<CueTime.framesPerSecond).contains(f) else {
            return nil
        }
        frames = (m * 60 + s) * CueTime.framesPerSecond + f
    }

    public var minutes: Int { frames / (60 * CueTime.framesPerSecond) }
    public var seconds: Int { (frames / CueTime.framesPerSecond) % 60 }
    public var frame: Int { frames % CueTime.framesPerSecond }
    public var totalSeconds: Double { Double(frames) / Double(CueTime.framesPerSecond) }

    public var msfString: String {
        String(format: "%02d:%02d:%02d", minutes, seconds, frame)
    }

    // Sample offset at the given rate (588 samples per frame at 44.1 kHz).
    public func samples(sampleRate: Int) -> Int {
        frames * sampleRate / CueTime.framesPerSecond
    }

    public static func < (lhs: CueTime, rhs: CueTime) -> Bool { lhs.frames < rhs.frames }
    public static func - (lhs: CueTime, rhs: CueTime) -> CueTime { CueTime(frames: lhs.frames - rhs.frames) }
}

public struct CueIndex: Sendable, Equatable, Hashable, Codable {
    public let number: Int
    public let time: CueTime
    // 0 when the time is relative to the track's own FILE. EAC's "gaps
    // appended to previous track" sheets put a track's INDEX 00 at the end
    // of one file and its INDEX 01 after the next FILE line: that index is
    // relative to a later file, `fileOffset` files after the track's.
    public let fileOffset: Int

    public init(number: Int, time: CueTime, fileOffset: Int = 0) {
        self.number = number
        self.time = time
        self.fileOffset = fileOffset
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = try c.decode(Int.self, forKey: .number)
        time = try c.decode(CueTime.self, forKey: .time)
        fileOffset = try c.decodeIfPresent(Int.self, forKey: .fileOffset) ?? 0
    }
}

public struct CueTrack: Sendable, Equatable, Hashable, Codable {
    public var number: Int
    public var type: String              // "AUDIO", "MODE1/2352", …
    public var title: String?
    public var performer: String?
    public var songwriter: String?
    public var isrc: String?
    public var flags: [String]
    public var pregap: CueTime?
    public var postgap: CueTime?
    public var indexes: [CueIndex]
    public var rems: [CueRem]

    public init(number: Int, type: String = "AUDIO") {
        self.number = number
        self.type = type
        self.flags = []
        self.indexes = []
        self.rems = []
    }

    public var isAudio: Bool { type.uppercased() == "AUDIO" }

    public func index(_ n: Int) -> CueTime? {
        indexes.first { $0.number == n }?.time
    }

    // INDEX 01 is where players start the track; INDEX 00 marks its pregap.
    public var start: CueTime? { index(1) }
    // How many FILEs after the track's own FILE its INDEX 01 is measured in.
    public var startFileOffset: Int { indexes.first { $0.number == 1 }?.fileOffset ?? 0 }
    public var pregapStart: CueTime? { index(0) }
}

public struct CueRem: Sendable, Equatable, Hashable, Codable {
    public let key: String     // upper-cased, e.g. "DISCID", "COMMENT", "DATE"
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

public struct CueFile: Sendable, Equatable, Hashable, Codable {
    public var name: String
    public var type: String              // "WAVE", "BINARY", "MP3", …
    public var tracks: [CueTrack]

    public init(name: String, type: String, tracks: [CueTrack] = []) {
        self.name = name
        self.type = type
        self.tracks = tracks
    }

    public func url(relativeTo folder: URL) -> URL {
        folder.appending(path: name, directoryHint: .notDirectory)
    }
}

public struct CueSheet: Sendable, Equatable, Hashable, Codable {
    public var catalog: String?          // UPC/EAN from the CATALOG command
    public var cdTextFile: String?
    public var title: String?
    public var performer: String?
    public var songwriter: String?
    public var rems: [CueRem]
    public var files: [CueFile]
    public var encodingName: String      // how the bytes were decoded (diagnostics)

    public init() {
        rems = []
        files = []
        encodingName = "utf-8"
    }

    public var tracks: [CueTrack] { files.flatMap(\.tracks) }
    public var audioTracks: [CueTrack] { tracks.filter(\.isAudio) }
    public var isSingleFile: Bool { files.count == 1 }

    public func rem(_ key: String) -> String? {
        rems.first { $0.key == key.uppercased() }?.value
    }

    public func referencedFiles(relativeTo folder: URL) -> [URL] {
        files.map { $0.url(relativeTo: folder) }
    }

    // Pregap of track 1 in a single-image rip: audio before INDEX 01 of
    // track 1. Whether it is a real hidden track (HTOA) or two seconds of
    // silence is decided at split time.
    public var trackOnePregap: CueTime? {
        guard let first = audioTracks.first, let start = first.start, start.frames > 0 else { return nil }
        return start
    }

    // MARK: Hints for release identification

    public var discID: String? { rem("DISCID") }
    public var date: String? { rem("DATE") }
    public var genre: String? { rem("GENRE") }

    // Barcode from CATALOG, or from a REM COMMENT such as
    // "Universal Music – UICY-40164\Barcode: 4988031277102\Reissue…".
    public var barcodeHint: String? {
        if let catalog, catalog.count >= 8, catalog.allSatisfy(\.isNumber), catalog != String(repeating: "0", count: catalog.count) {
            return catalog
        }
        for rem in rems where rem.key == "COMMENT" || rem.key == "BARCODE" {
            if let match = rem.value.firstMatch(of: #/(?i)barcode\s*[:=]?\s*([0-9][0-9 ]{7,}[0-9])/#) {
                return String(match.1).replacingOccurrences(of: " ", with: "")
            }
            if rem.key == "BARCODE" {
                let digits = rem.value.filter(\.isNumber)
                if digits.count >= 8 { return digits }
            }
        }
        return nil
    }

    // Catalog-number-looking tokens in comments, e.g. "UICY-40164", "FCD 8410-2".
    public var catalogNumberHints: [String] {
        var out: [String] = []
        let sources = rems.filter { $0.key == "COMMENT" || $0.key == "CATALOGNUMBER" || $0.key == "CATNO" }.map(\.value)
        for text in sources {
            for match in text.matches(of: #/\b([A-Z]{2,10})[- ]?(\d{3,7}(?:-\d{1,2})?)\b/#) {
                out.append("\(match.1)-\(match.2)")
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    // MARK: Parsing

    public enum ParseError: LocalizedError, Equatable {
        case empty
        case noFiles
        case trackOutsideFile(line: Int)

        public var errorDescription: String? {
            switch self {
            case .empty: return "The CUE sheet is empty."
            case .noFiles: return "The CUE sheet has no FILE entries."
            case .trackOutsideFile(let line): return "TRACK before any FILE at line \(line)."
            }
        }
    }

    public static func parse(url: URL) throws -> CueSheet {
        try parse(data: Data(contentsOf: url))
    }

    public static func parse(data: Data) throws -> CueSheet {
        let decoded = TextDecoder.decode(data)
        var sheet = try parse(text: decoded.text)
        sheet.encodingName = decoded.encodingName
        return sheet
    }

    public static func parse(text: String) throws -> CueSheet {
        var sheet = CueSheet()
        var fileIndex: Int? = nil
        var trackIndex: Int? = nil
        var lastTrack: (file: Int, track: Int)? = nil   // survives a FILE line
        var lineNumber = 0
        var sawAnything = false

        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            lineNumber += 1
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            sawAnything = true
            let tokens = tokenize(line)
            guard let command = tokens.first?.uppercased() else { continue }
            let args = Array(tokens.dropFirst())

            switch command {
            case "REM":
                guard let key = args.first else { continue }
                let value = unquoted(remainder(of: line, afterTokens: 2))
                let rem = CueRem(key: key.uppercased(), value: value)
                if let fi = fileIndex, let ti = trackIndex {
                    sheet.files[fi].tracks[ti].rems.append(rem)
                } else {
                    sheet.rems.append(rem)
                }

            case "CATALOG":
                sheet.catalog = args.first

            case "CDTEXTFILE":
                sheet.cdTextFile = unquoted(remainder(of: line, afterTokens: 1))

            case "FILE":
                // FILE "name" TYPE — the type is the last token; unquoted
                // names with spaces put everything in between.
                guard args.count >= 1 else { continue }
                let type = args.count >= 2 ? args[args.count - 1].uppercased() : "WAVE"
                let name = args.count >= 2 ? args[0..<(args.count - 1)].joined(separator: " ") : args[0]
                sheet.files.append(CueFile(name: name, type: type))
                fileIndex = sheet.files.count - 1
                trackIndex = nil

            case "TRACK":
                guard let fi = fileIndex else { throw ParseError.trackOutsideFile(line: lineNumber) }
                let number = args.first.flatMap { Int($0) } ?? (sheet.tracks.count + 1)
                let type = args.count >= 2 ? args[1].uppercased() : "AUDIO"
                sheet.files[fi].tracks.append(CueTrack(number: number, type: type))
                trackIndex = sheet.files[fi].tracks.count - 1
                lastTrack = (fi, trackIndex!)

            case "INDEX":
                guard let fi = fileIndex, args.count >= 2, let n = Int(args[0]), let time = CueTime(msf: args[1]) else { continue }
                if let ti = trackIndex {
                    sheet.files[fi].tracks[ti].indexes.append(CueIndex(number: n, time: time))
                } else if let last = lastTrack {
                    // INDEX after a new FILE and before any TRACK: it still
                    // belongs to the previous track, measured in this file.
                    sheet.files[last.file].tracks[last.track].indexes.append(CueIndex(number: n, time: time, fileOffset: fi - last.file))
                }

            case "PREGAP", "POSTGAP":
                guard let fi = fileIndex, let ti = trackIndex, let arg = args.first,
                      let time = CueTime(msf: arg) else { continue }
                if command == "PREGAP" {
                    sheet.files[fi].tracks[ti].pregap = time
                } else {
                    sheet.files[fi].tracks[ti].postgap = time
                }

            case "TITLE", "PERFORMER", "SONGWRITER", "ISRC", "FLAGS":
                let value = unquoted(remainder(of: line, afterTokens: 1))
                if let fi = fileIndex, let ti = trackIndex {
                    switch command {
                    case "TITLE": sheet.files[fi].tracks[ti].title = value
                    case "PERFORMER": sheet.files[fi].tracks[ti].performer = value
                    case "SONGWRITER": sheet.files[fi].tracks[ti].songwriter = value
                    case "ISRC": sheet.files[fi].tracks[ti].isrc = value
                    default: sheet.files[fi].tracks[ti].flags = args.map { $0.uppercased() }
                    }
                } else {
                    switch command {
                    case "TITLE": sheet.title = value
                    case "PERFORMER": sheet.performer = value
                    case "SONGWRITER": sheet.songwriter = value
                    default: break
                    }
                }

            default:
                continue
            }
        }

        guard sawAnything else { throw ParseError.empty }
        guard !sheet.files.isEmpty else { throw ParseError.noFiles }
        return sheet
    }

    // Splits on whitespace, keeping quoted strings together (quotes removed).
    static func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        var hadQuotes = false
        for ch in line {
            if ch == "\"" {
                inQuotes.toggle()
                hadQuotes = true
                continue
            }
            if (ch == " " || ch == "\t") && !inQuotes {
                if !current.isEmpty || hadQuotes {
                    tokens.append(current)
                    current = ""
                    hadQuotes = false
                }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty || hadQuotes {
            tokens.append(current)
        }
        return tokens
    }

    // Everything after the first `count` whitespace-separated tokens, so
    // TITLE values keep their internal spacing and quotes can be stripped.
    static func remainder(of line: String, afterTokens count: Int) -> String {
        var index = line.startIndex
        var tokensSeen = 0
        while tokensSeen < count && index < line.endIndex {
            while index < line.endIndex, line[index] == " " || line[index] == "\t" { index = line.index(after: index) }
            while index < line.endIndex, line[index] != " ", line[index] != "\t" { index = line.index(after: index) }
            tokensSeen += 1
        }
        return String(line[index...]).trimmingCharacters(in: .whitespaces)
    }

    static func unquoted(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.count >= 2, t.hasPrefix("\""), t.hasSuffix("\"") {
            t.removeFirst()
            t.removeLast()
        }
        return t
    }
}

// MARK: - Encoding detection

// CUE sheets have no encoding declaration and come from Windows tools in
// every locale. UTF-8 is tried first; for 8-bit files the byte patterns
// decide between Shift-JIS (runs of double-byte characters), CP1251 (runs
// of Cyrillic letters) and CP1252 / Latin-1 (isolated accents and smart
// quotes, by far the most common case).
public enum TextDecoder {

    public struct Decoded: Sendable, Equatable {
        public let text: String
        public let encodingName: String
    }

    public static func decode(_ data: Data) -> Decoded {
        let bytes = [UInt8](data)

        if bytes.starts(with: [0xEF, 0xBB, 0xBF]), let s = String(bytes: bytes.dropFirst(3), encoding: .utf8) {
            return Decoded(text: s, encodingName: "utf-8-bom")
        }
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]), let s = String(data: data, encoding: .utf16) {
            return Decoded(text: s, encodingName: "utf-16")
        }
        if let s = String(data: data, encoding: .utf8) {
            return Decoded(text: s, encodingName: bytes.contains { $0 >= 0x80 } ? "utf-8" : "ascii")
        }

        if isPlausibleShiftJIS(bytes), let s = String(data: data, encoding: .shiftJIS) {
            return Decoded(text: s, encodingName: "shift_jis")
        }
        if let s = String(data: data, encoding: .windowsCP1251), hasCyrillicWord(s) {
            return Decoded(text: s, encodingName: "cp1251")
        }
        if let s = String(data: data, encoding: .windowsCP1252) {
            return Decoded(text: s, encodingName: "cp1252")
        }
        if let s = String(data: data, encoding: .isoLatin1) {
            return Decoded(text: s, encodingName: "iso-8859-1")
        }
        return Decoded(text: String(decoding: data, as: UTF8.self), encodingName: "utf-8-lossy")
    }

    // Every high byte must form a valid Shift-JIS sequence, and there must
    // be at least one run of two consecutive double-byte characters. A
    // CP1252 apostrophe (0x92 's') happens to be a valid lead+trail pair,
    // but never two in a row.
    static func isPlausibleShiftJIS(_ bytes: [UInt8]) -> Bool {
        var i = 0
        var run = 0
        var sawRun = false
        var sawHigh = false
        while i < bytes.count {
            let b = bytes[i]
            if b < 0x80 {
                run = 0
                i += 1
                continue
            }
            sawHigh = true
            if (0xA1...0xDF).contains(b) {          // half-width katakana
                run += 1
                if run >= 2 { sawRun = true }
                i += 1
                continue
            }
            let isLead = (0x81...0x9F).contains(b) || (0xE0...0xFC).contains(b)
            guard isLead, i + 1 < bytes.count else { return false }
            let t = bytes[i + 1]
            let validTrail = (0x40...0x7E).contains(t) || (0x80...0xFC).contains(t)
            guard validTrail else { return false }
            run += 1
            if run >= 2 { sawRun = true }
            i += 2
        }
        return sawHigh && sawRun
    }

    // Three or more consecutive Cyrillic letters somewhere in the text.
    static func hasCyrillicWord(_ s: String) -> Bool {
        var run = 0
        for scalar in s.unicodeScalars {
            if (0x0400...0x04FF).contains(scalar.value) {
                run += 1
                if run >= 3 { return true }
            } else {
                run = 0
            }
        }
        return false
    }
}
