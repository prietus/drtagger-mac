import Foundation

// Resolves which ffmpeg/ffprobe the app should drive. Search order:
//   1. an explicit override path from Settings > Advanced,
//   2. the LGPL binaries embedded in the app bundle (Contents/Helpers),
//   3. common Homebrew / MacPorts locations (development fallback; those
//      builds are GPL and must never be redistributed).
struct FFmpegLocator: Sendable, Equatable {

    enum Source: String, Sendable {
        case override
        case bundled
        case system
    }

    struct Location: Sendable, Equatable {
        let ffmpeg: URL
        let ffprobe: URL?
        let source: Source
    }

    struct Info: Sendable, Equatable {
        let location: Location
        let versionLine: String     // "ffmpeg version 8.0 Copyright …"
        let isGPL: Bool             // configuration contains --enable-gpl
        let hasDSTDecoder: Bool
    }

    enum LocateError: LocalizedError {
        case notFound
        case notExecutable(String)

        var errorDescription: String? {
            switch self {
            case .notFound:
                return "No ffmpeg found. Run scripts/build-ffmpeg.sh or set a path in Settings > Advanced."
            case .notExecutable(let p):
                return "\(p) exists but could not be executed."
            }
        }
    }

    let overridePath: String

    static let systemCandidates: [String] = [
        "/opt/homebrew/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
        "/opt/local/bin/ffmpeg",
    ]

    static var bundledURL: URL {
        Bundle.main.bundleURL
            .appending(path: "Contents/Helpers/ffmpeg", directoryHint: .notDirectory)
    }

    func locate() -> Location? {
        let fm = FileManager.default
        if !overridePath.isEmpty {
            let url = URL(fileURLWithPath: overridePath)
            if fm.isExecutableFile(atPath: url.path) {
                return Location(ffmpeg: url, ffprobe: Self.sibling(of: url), source: .override)
            }
        }
        let bundled = Self.bundledURL
        if fm.isExecutableFile(atPath: bundled.path) {
            return Location(ffmpeg: bundled, ffprobe: Self.sibling(of: bundled), source: .bundled)
        }
        for path in Self.systemCandidates where fm.isExecutableFile(atPath: path) {
            let url = URL(fileURLWithPath: path)
            return Location(ffmpeg: url, ffprobe: Self.sibling(of: url), source: .system)
        }
        return nil
    }

    // Runs `ffmpeg -version` and inspects the configuration line.
    func inspect() async throws -> Info {
        guard let location = locate() else { throw LocateError.notFound }
        let result = try await ProcessRunner.run(location.ffmpeg, arguments: ["-hide_banner", "-version"])
        guard result.status == 0 else {
            throw LocateError.notExecutable(location.ffmpeg.path)
        }
        let text = result.stdoutText
        let versionLine = text.split(separator: "\n").first.map(String.init) ?? ""
        let isGPL = text.contains("--enable-gpl")

        let decoders = try await ProcessRunner.run(location.ffmpeg, arguments: ["-hide_banner", "-decoders"])
        let hasDST = decoders.stdoutText
            .split(separator: "\n")
            .contains { line in
                let cols = line.split(separator: " ", omittingEmptySubsequences: true)
                return cols.count >= 2 && cols[1] == "dst"
            }

        return Info(location: location, versionLine: versionLine, isGPL: isGPL, hasDSTDecoder: hasDST)
    }

    private static func sibling(of ffmpeg: URL) -> URL? {
        let probe = ffmpeg.deletingLastPathComponent().appending(path: "ffprobe", directoryHint: .notDirectory)
        return FileManager.default.isExecutableFile(atPath: probe.path) ? probe : nil
    }
}
