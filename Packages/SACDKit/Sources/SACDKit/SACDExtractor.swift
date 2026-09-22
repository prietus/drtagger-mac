import DSTKit
import FLACKit
import Foundation
import LibraryKit
import SplitKit

public struct SACDExtractOptions: Sendable, Equatable {
    public enum PausePolicy: String, Sendable, Codable, CaseIterable {
        // Audio between a track's end (its TOC duration) and the next track's
        // start stays at the end of the previous track, like CD gaps appended.
        case appendToPrevious
        // Only the TOC duration of each track is written (sacd_extract behaviour).
        case drop
    }

    public var pausePolicy: PausePolicy = .appendToPrevious
    public var albumFolderTemplate: String = PathTemplate.defaultAlbumFolder
    public var trackFileTemplate: String = PathTemplate.defaultTrackFile
    public var asciiFileNames: Bool = false
    public var multichannelSubfolder: String = "Multichannel"
    public var writeTags: Bool = true
    public var overwriteExisting: Bool = false
    public var leadInWarningFrames: Int = 150

    public init() {}
}

public struct SACDTrackOutput: Sendable, Equatable, Codable {
    public let number: Int
    public let title: String?
    public let url: URL
    public let frames: Int
    public let expectedFrames: Int          // TOC duration (drop) or gap to next track (append)
    public let sampleCount: UInt64          // per channel
    public let fileSize: UInt64
    public let contiguous: Bool             // frame timecodes advanced by exactly one

    public var verified: Bool { frames == expectedFrames && contiguous }
}

public struct SACDExtractOutcome: Sendable, Equatable, Codable {
    public let outputFolder: URL
    public let isMultichannel: Bool
    public let channelCount: Int
    public let tracks: [SACDTrackOutput]
    public let droppedLeadInFrames: Int
    public let droppedPauseFrames: Int
    public let elapsedSeconds: Double
    public let warnings: [String]

    public var verified: Bool { !tracks.isEmpty && tracks.allSatisfy(\.verified) }
}

public enum SACDExtractError: LocalizedError, Equatable {
    case dstDecodeFailed(timecode: String, reason: String)
    case noTracks
    case outputExists(String)
    case frameSizeMismatch(expected: Int, got: Int, timecode: String)

    public var errorDescription: String? {
        switch self {
        case .dstDecodeFailed(let t, let r): return "DST frame at \(t) could not be decoded: \(r)"
        case .noTracks: return "The area has no tracks."
        case .outputExists(let n): return "\(n) already exists. Enable overwrite to replace it."
        case .frameSizeMismatch(let e, let g, let t): return "Frame at \(t) has \(g) bytes, expected \(e)."
        }
    }
}

public struct SACDExtractProgress: Sendable, Equatable {
    public let fraction: Double
    public let message: String
}

// Extracts one area of a SACD image into per-track DSF files with ID3 tags
// built from the disc's own text (title, performer, ISRC, genre, date).
// Synchronous and CPU-bound: callers run it off the main actor.
public struct SACDExtractor: Sendable {

    public init() {}

    public func extract(
        disc: SACDDisc,
        area: SACDArea,
        destinationRoot: URL,
        options: SACDExtractOptions = SACDExtractOptions(),
        progress: @escaping @Sendable (SACDExtractProgress) -> Void = { _ in }
    ) throws -> SACDExtractOutcome {
        let started = Date()
        guard !area.tracks.isEmpty else { throw SACDExtractError.noTracks }
        var warnings: [String] = []

        // Output folder.
        let albumArtist = disc.artist ?? area.tracks.first?.performer ?? "Unknown Artist"
        let album = disc.title ?? disc.url.deletingPathExtension().lastPathComponent
        var relative = PathTemplate.render(options.albumFolderTemplate, values: [
            "albumartist": albumArtist,
            "album": album,
            "year": disc.year ?? "",
        ], ascii: options.asciiFileNames)
        if disc.info.albumSetSize > 1 {
            relative += "/Disc \(disc.info.albumSequenceNumber)"
        }
        if area.isMultichannel, !options.multichannelSubfolder.isEmpty {
            relative += "/" + PathTemplate.sanitizeComponent(options.multichannelSubfolder)
        }
        let outputFolder = relative.isEmpty ? destinationRoot : destinationRoot.appending(path: relative, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)

        // Track windows in frames.
        struct Window { let track: SACDTrack; let start: Int; let end: Int; let url: URL }
        var windows: [Window] = []
        for (i, track) in area.tracks.enumerated() {
            let start = track.startTime.totalFrames
            let nextStart = i + 1 < area.tracks.count ? area.tracks[i + 1].startTime.totalFrames : Int.max
            let end: Int
            switch options.pausePolicy {
            case .drop: end = min(start + track.duration.totalFrames, nextStart)
            case .appendToPrevious: end = nextStart
            }
            let name = PathTemplate.render(options.trackFileTemplate, values: [
                "track": String(format: "%02d", track.number),
                "title": track.title ?? "Track \(track.number)",
                "artist": track.performer ?? albumArtist,
                "album": album,
            ], ascii: options.asciiFileNames)
            let url = outputFolder.appending(path: (name.isEmpty ? String(format: "%02d", track.number) : name) + ".dsf", directoryHint: .notDirectory)
            if FileManager.default.fileExists(atPath: url.path) {
                guard options.overwriteExisting else { throw SACDExtractError.outputExists(url.lastPathComponent) }
                try FileManager.default.removeItem(at: url)
            }
            windows.append(Window(track: track, start: start, end: end, url: url))
        }

        // Stream frames; DST areas are decoded in parallel batches.
        let reader = try SACDFrameReader(url: disc.url, firstSector: area.audioStartSector, lastSector: area.audioEndSector)
        let frameBytes = area.dsdFrameBytes
        let dstBatch: DSTBatchDecoder? = area.isDST ? try DSTBatchDecoder(channels: area.channelCount, sampleRate: area.sampleRate) : nil
        var decoded: [SACDFrame] = []
        var decodedIndex = 0
        func nextFrame() throws -> SACDFrame? {
            guard let dstBatch else { return try reader.next() }
            if decodedIndex == decoded.count {
                var batch: [SACDFrame] = []
                while batch.count < dstBatch.batchSize, let f = try reader.next() { batch.append(f) }
                if batch.isEmpty { return nil }
                decoded = try dstBatch.decode(batch)
                decodedIndex = 0
            }
            defer { decodedIndex += 1 }
            return decoded[decodedIndex]
        }
        var outputs: [SACDTrackOutput] = []
        var windowIndex = 0
        var writer: DSFWriter? = nil
        var writerFrames = 0
        var writerContiguous = true
        var lastTimecode: Int? = nil
        var droppedLeadIn = 0
        var droppedPause = 0
        var lastWindowEnd = 0
        var frameCounter = 0
        let totalFrames = max(1, area.playTime.totalFrames)

        func closeWriter(_ w: Window) throws {
            guard let current = writer else { return }
            let tags = options.writeTags ? Self.id3(for: w.track, disc: disc, area: area) : nil
            let (samples, size) = try current.finish(id3: tags)
            let expected = w.end == Int.max ? writerFrames : (w.end - w.start)
            outputs.append(SACDTrackOutput(
                number: w.track.number, title: w.track.title, url: current.url,
                frames: writerFrames, expectedFrames: expected,
                sampleCount: samples, fileSize: size, contiguous: writerContiguous
            ))
            writer = nil
            writerFrames = 0
            writerContiguous = true
        }

        while let frame = try nextFrame() {
            try Task.checkCancellation()
            frameCounter += 1
            if frameCounter % 750 == 0 {
                progress(SACDExtractProgress(fraction: min(0.99, Double(frameCounter) / Double(totalFrames)),
                                             message: "Track \(min(windowIndex + 1, windows.count)) of \(windows.count)"))
            }
            let t = frame.timecode.totalFrames
            if let last = lastTimecode, t != last + 1, writer != nil {
                writerContiguous = false
            }
            lastTimecode = t

            // Advance past windows that ended.
            while windowIndex < windows.count && t >= windows[windowIndex].end {
                try closeWriter(windows[windowIndex])
                lastWindowEnd = windows[windowIndex].end
                windowIndex += 1
            }
            guard windowIndex < windows.count else { break }
            let w = windows[windowIndex]
            if t < w.start {
                if windowIndex == 0 { droppedLeadIn += 1 } else { droppedPause += 1 }
                continue
            }
            guard frame.data.count == frameBytes else {
                throw SACDExtractError.frameSizeMismatch(expected: frameBytes, got: frame.data.count, timecode: frame.timecode.description)
            }
            if writer == nil {
                writer = try DSFWriter(url: w.url, channelCount: area.channelCount, sampleRate: area.sampleRate)
                writerFrames = 0
                writerContiguous = true
            }
            try writer!.write(interleavedFrame: frame.data)
            writerFrames += 1
        }
        if windowIndex < windows.count {
            try closeWriter(windows[windowIndex])
            windowIndex += 1
        }
        _ = lastWindowEnd
        if outputs.count < windows.count {
            warnings.append("Only \(outputs.count) of \(windows.count) tracks had audio.")
        }
        if droppedLeadIn > options.leadInWarningFrames {
            warnings.append("\(droppedLeadIn) frames before track 1 were skipped (possible hidden audio).")
        }
        progress(SACDExtractProgress(fraction: 1, message: "Done"))

        return SACDExtractOutcome(
            outputFolder: outputFolder,
            isMultichannel: area.isMultichannel,
            channelCount: area.channelCount,
            tracks: outputs,
            droppedLeadInFrames: droppedLeadIn,
            droppedPauseFrames: droppedPause,
            elapsedSeconds: Date().timeIntervalSince(started),
            warnings: warnings
        )
    }

    // MARK: Tags

    public static func comment(for track: SACDTrack, disc: SACDDisc, area: SACDArea) -> VorbisComment {
        var fields: [(name: String, value: String)] = []
        func add(_ name: String, _ value: String?) {
            guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return }
            fields.append((name, v))
        }
        add("TITLE", track.title ?? "Track \(track.number)")
        add("ARTIST", track.performer ?? disc.artist)
        add("ALBUM", disc.title)
        add("ALBUMARTIST", disc.artist)
        add("TRACKNUMBER", String(track.number))
        add("TRACKTOTAL", String(area.tracks.count))
        if disc.info.albumSetSize > 1 {
            add("DISCNUMBER", String(disc.info.albumSequenceNumber))
            add("DISCTOTAL", String(disc.info.albumSetSize))
        }
        add("DATE", disc.year)
        add("GENRE", track.genre)
        add("COMPOSER", track.composer)
        add("ISRC", track.isrc)
        add("CATALOGNUMBER", disc.info.discCatalogNumber.isEmpty ? nil : disc.info.discCatalogNumber)
        add("MEDIA", "SACD")
        return VorbisComment(vendor: "drtagger for Mac", fields: fields)
    }

    static func id3(for track: SACDTrack, disc: SACDDisc, area: SACDArea) -> Data {
        ID3v2Bridge.toID3v23(comment(for: track, disc: disc, area: area)).encodedV23()
    }
}

// Decodes DST frames concurrently, one decoder per slot, keeping order.
final class DSTBatchDecoder {
    let batchSize: Int
    private let decoders: [DSTDecoder]

    init(channels: Int, sampleRate: Int, batchSize: Int = 48) throws {
        self.batchSize = batchSize
        decoders = try (0..<batchSize).map { _ in try DSTDecoder(channels: channels, sampleRate: sampleRate) }
    }

    func decode(_ frames: [SACDFrame]) throws -> [SACDFrame] {
        precondition(frames.count <= batchSize)
        let results = UnsafeMutablePointer<Data?>.allocate(capacity: frames.count)
        results.initialize(repeating: nil, count: frames.count)
        defer { results.deinitialize(count: frames.count); results.deallocate() }
        let errors = UnsafeMutablePointer<(any Error)?>.allocate(capacity: frames.count)
        errors.initialize(repeating: nil, count: frames.count)
        defer { errors.deinitialize(count: frames.count); errors.deallocate() }

        DispatchQueue.concurrentPerform(iterations: frames.count) { i in
            do {
                results[i] = try decoders[i].decode(frames[i].data)
            } catch {
                errors[i] = error
            }
        }
        var out: [SACDFrame] = []
        out.reserveCapacity(frames.count)
        for i in 0..<frames.count {
            if let e = errors[i] {
                throw SACDExtractError.dstDecodeFailed(timecode: frames[i].timecode.description, reason: e.localizedDescription)
            }
            out.append(SACDFrame(timecode: frames[i].timecode, data: results[i]!))
        }
        return out
    }
}
