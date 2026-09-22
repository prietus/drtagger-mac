import FLACKit
import Foundation
import LibraryKit

public struct SplitOptions: Sendable, Equatable {
    public var compressionLevel: Int = 8
    public var htoaThresholdFrames: Int = 150
    public var albumFolderTemplate: String = PathTemplate.defaultAlbumFolder
    public var trackFileTemplate: String = PathTemplate.defaultTrackFile
    public var asciiFileNames: Bool = false
    public var writeProvisionalTags: Bool = true
    public var overwriteExisting: Bool = false

    public init() {}
}

public struct SplitProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case probing
        case decoding(file: Int, of: Int)
        case encoding(track: Int, of: Int)
        case verifying
        case finished
    }
    public let phase: Phase
    public let fraction: Double     // 0…1 overall estimate

    public init(phase: Phase, fraction: Double) {
        self.phase = phase
        self.fraction = fraction
    }
}

public struct SplitTrackOutput: Sendable, Equatable, Codable {
    public let number: Int
    public let title: String?
    public let url: URL
    public let samples: Int64
    public let md5Hex: String            // MD5 of the PCM fed to the encoder
    public let streamInfoMD5Matches: Bool
    public let crc32: UInt32             // plain CRC of the whole track
    public let ctdbCRC32: UInt32?        // CUETools DB stride-adjusted CRC (CD audio only)
    public let verified: Bool
}

public struct SplitOutcome: Sendable, Equatable, Codable {
    public let outputFolder: URL
    public let format: PCMFormat
    public let plan: CueSplitPlan
    public let toc: DiscTOC?
    public let tracks: [SplitTrackOutput]
    public let ctdbDiscCRC32: UInt32?
    public let verified: Bool
    public let elapsedSeconds: Double
    public let warnings: [String]

    public var ctdbTrackCRC32s: [UInt32]? {
        let crcs = tracks.filter { $0.number > 0 }.compactMap(\.ctdbCRC32)
        return crcs.count == tracks.filter { $0.number > 0 }.count ? crcs : nil
    }
}

public enum SplitError: LocalizedError, Equatable {
    case noCueSheet
    case missingFile(String)
    case mixedFormats(String)
    case outputExists(String)
    case notCDFrameAligned

    public var errorDescription: String? {
        switch self {
        case .noCueSheet: return "This disc has no CUE sheet to split with."
        case .missingFile(let n): return "The CUE references \(n), which does not exist."
        case .mixedFormats(let n): return "\(n) has a different sample format than the first file."
        case .outputExists(let n): return "\(n) already exists. Enable overwrite to replace it."
        case .notCDFrameAligned: return "The image length is not a whole number of CD frames."
        }
    }
}

// Turns one disc (image + CUE, or per-track files + CUE) into verified FLAC
// tracks. Work happens in a temporary folder; nothing is written to the
// destination until the encode of that track succeeded.
public actor ImageSplitter {

    public let tool: FFmpegTool

    public init(tool: FFmpegTool) {
        self.tool = tool
    }

    public func split(
        disc: DetectedDisc,
        album: ProvisionalTags.AlbumContext,
        destinationRoot: URL,
        options: SplitOptions = SplitOptions(),
        progress: @escaping @Sendable (SplitProgress) -> Void = { _ in }
    ) async throws -> SplitOutcome {
        let started = Date()
        guard let cue = disc.cue else { throw SplitError.noCueSheet }
        var warnings: [String] = []

        // 1. Source files, in CUE order.
        let sources = cue.files.map { $0.url(relativeTo: disc.folder) }
        for s in sources where !FileManager.default.fileExists(atPath: s.path) {
            throw SplitError.missingFile(s.lastPathComponent)
        }

        // 2. Probe: all files must share one PCM format.
        progress(SplitProgress(phase: .probing, fraction: 0))
        let firstInfo = try await tool.probe(sources[0])
        let format = try firstInfo.pcmFormat
        for s in sources.dropFirst() {
            let info = try await tool.probe(s)
            guard info.sampleRate == firstInfo.sampleRate, info.channels == firstInfo.channels,
                  (try info.pcmFormat) == format else {
                throw SplitError.mixedFormats(s.lastPathComponent)
            }
        }

        // 3. Decode everything into one raw file.
        let work = FileManager.default.temporaryDirectory.appending(path: "drtagger-split-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let raw = work.appending(path: "image.raw")
        var fileSampleCounts: [Int64] = []
        if sources.count == 1 {
            progress(SplitProgress(phase: .decoding(file: 1, of: 1), fraction: 0.05))
            fileSampleCounts = [try await tool.decodeToRaw(sources[0], format: format, to: raw)]
        } else {
            FileManager.default.createFile(atPath: raw.path, contents: nil)
            let sink = try FileHandle(forWritingTo: raw)
            defer { try? sink.close() }
            for (i, s) in sources.enumerated() {
                progress(SplitProgress(phase: .decoding(file: i + 1, of: sources.count), fraction: 0.05 + 0.35 * Double(i) / Double(sources.count)))
                let part = work.appending(path: "part\(i).raw")
                let samples = try await tool.decodeToRaw(s, format: format, to: part)
                try Self.append(part, to: sink)
                try FileManager.default.removeItem(at: part)
                fileSampleCounts.append(samples)
            }
        }
        let totalSamples = fileSampleCounts.reduce(0, +)

        // 4. Plan and TOC.
        let plan = try CueSplitPlan.make(cue: cue, fileSampleCounts: fileSampleCounts, sampleRate: format.sampleRate, htoaThresholdFrames: options.htoaThresholdFrames)
        let samplesPerFrame = Int64(format.sampleRate / CueTime.framesPerSecond)
        var toc: DiscTOC? = nil
        if fileSampleCounts.allSatisfy({ $0 % samplesPerFrame == 0 }) {
            toc = try? DiscTOC(cue: cue, fileFrames: fileSampleCounts.map { Int($0 / samplesPerFrame) })
        } else {
            warnings.append("Image length is not frame aligned; no disc ID computed.")
        }

        // Disc IDs derived here complete the context the caller passed.
        var album = album
        if album.musicBrainzDiscID == nil { album.musicBrainzDiscID = toc?.musicBrainzDiscID }
        if album.discID == nil { album.discID = cue.discID ?? toc?.freeDBDiscID }

        // 5. Destination folder.
        var albumValues: [String: String] = [
            "albumartist": album.albumArtist ?? cue.performer ?? "Unknown Artist",
            "album": album.album ?? cue.title ?? disc.folder.lastPathComponent,
            "year": album.date.map { String($0.prefix(4)) } ?? "",
        ]
        if let n = album.discNumber { albumValues["disc"] = String(n) }
        var relative = PathTemplate.render(options.albumFolderTemplate, values: albumValues, ascii: options.asciiFileNames)
        if let total = album.discTotal, total > 1, let n = album.discNumber {
            relative += "/Disc \(n)"
        }
        let outputFolder = relative.isEmpty ? destinationRoot : destinationRoot.appending(path: relative, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)

        // 6. Encode and verify each track.
        var outputs: [SplitTrackOutput] = []
        let numbered = plan.numberedTracks
        let firstStart = numbered.first?.startSample ?? 0
        let discEnd = numbered.last?.endSample ?? totalSamples
        let stride = Int64(5880)
        let ctdbApplies = format.isCDAudio && toc != nil

        for (i, track) in plan.tracks.enumerated() {
            progress(SplitProgress(phase: .encoding(track: i + 1, of: plan.tracks.count), fraction: 0.4 + 0.55 * Double(i) / Double(plan.tracks.count)))
            let title = track.isHiddenTrack ? "Hidden Track" : (track.title ?? "Track \(track.number)")
            let name = PathTemplate.render(options.trackFileTemplate, values: [
                "track": String(format: "%02d", track.number),
                "title": title,
                "artist": track.performer ?? album.albumArtist ?? "",
                "album": albumValues["album"] ?? "",
            ], ascii: options.asciiFileNames)
            let url = outputFolder.appending(path: (name.isEmpty ? String(format: "%02d", track.number) : name) + ".flac", directoryHint: .notDirectory)
            if FileManager.default.fileExists(atPath: url.path) {
                guard options.overwriteExisting else { throw SplitError.outputExists(url.lastPathComponent) }
                try FileManager.default.removeItem(at: url)
            }

            let range = format.byteOffset(ofSample: track.startSample)..<format.byteOffset(ofSample: track.endSample)
            let digest = try await tool.encodeFLAC(rawPCM: raw, byteRange: range, format: format, compressionLevel: options.compressionLevel, to: url)

            // Verify: STREAMINFO MD5 must equal the MD5 of the bytes fed. If
            // the encoder's MD5 differs (bit-depth packing quirks), fall back
            // to decoding the track and comparing CRCs.
            let flac = try FLACFile(url: url)
            let samplesOK = Int64(flac.streamInfo.totalSamples) == track.sampleCount
            var md5OK = flac.streamInfo.md5Signature == digest.md5
            var verified = samplesOK && md5OK
            if samplesOK && !md5OK {
                let (crc, samples) = try await tool.rawChecksum(url, format: format)
                verified = crc == digest.crc32 && samples == track.sampleCount
                if verified {
                    warnings.append("\(url.lastPathComponent): STREAMINFO MD5 differs from the fed PCM; verified by decode instead.")
                }
                md5OK = false
            }
            if !verified {
                warnings.append("\(url.lastPathComponent): verification FAILED (samples \(flac.streamInfo.totalSamples) vs \(track.sampleCount)).")
            }

            var ctdb: UInt32? = nil
            if ctdbApplies && !track.isHiddenTrack {
                var s = track.startSample, e = track.endSample
                if track.startSample == firstStart { s += stride }
                if track.endSample == discEnd { e -= stride }
                if e > s {
                    ctdb = try CRC32.checksum(fileAt: raw, range: format.byteOffset(ofSample: s)..<format.byteOffset(ofSample: e))
                }
            }

            if options.writeProvisionalTags {
                let comment = ProvisionalTags.comment(for: track, trackTotal: numbered.count, album: album)
                try ProvisionalTags.write(comment, to: url)
            }

            outputs.append(SplitTrackOutput(
                number: track.number,
                title: track.isHiddenTrack ? nil : track.title,
                url: url,
                samples: track.sampleCount,
                md5Hex: digest.md5Hex,
                streamInfoMD5Matches: md5OK,
                crc32: digest.crc32,
                ctdbCRC32: ctdb,
                verified: verified
            ))
        }

        progress(SplitProgress(phase: .verifying, fraction: 0.97))
        var discCRC: UInt32? = nil
        if ctdbApplies, discEnd - stride > firstStart + stride {
            discCRC = try CRC32.checksum(fileAt: raw, range: format.byteOffset(ofSample: firstStart + stride)..<format.byteOffset(ofSample: discEnd - stride))
        }

        progress(SplitProgress(phase: .finished, fraction: 1))
        return SplitOutcome(
            outputFolder: outputFolder,
            format: format,
            plan: plan,
            toc: toc,
            tracks: outputs,
            ctdbDiscCRC32: discCRC,
            verified: outputs.allSatisfy(\.verified),
            elapsedSeconds: Date().timeIntervalSince(started),
            warnings: warnings
        )
    }

    private static func append(_ source: URL, to sink: FileHandle) throws {
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        while let chunk = try reader.read(upToCount: 4 << 20), !chunk.isEmpty {
            try sink.write(contentsOf: chunk)
        }
    }
}
