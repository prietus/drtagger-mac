import FLACKit
import Foundation
import LibraryKit
import Observation
import ProviderKit
import SACDKit
import SplitKit
import SwiftData

// Per-album disc operations for CUE-based albums: TOC and disc IDs,
// CUETools DB lookup / verification, and splitting into the library.
// Results are persisted on the AlbumRecord; transient progress lives here,
// keyed by record path.
@Observable
@MainActor
final class DiscService {

    struct Activity: Equatable {
        var message: String
        var fraction: Double?
    }

    private(set) var activity: [String: Activity] = [:]
    private(set) var errors: [String: String] = [:]

    static let userAgent = "drtagger-mac/0.1 (+https://drtagger.priet.us)"

    func isBusy(_ record: AlbumRecord) -> Bool { activity[record.path] != nil }
    func activity(for record: AlbumRecord) -> Activity? { activity[record.path] }
    func error(for record: AlbumRecord) -> String? { errors[record.path] }

    private func begin(_ record: AlbumRecord, _ message: String, fraction: Double? = nil) {
        activity[record.path] = Activity(message: message, fraction: fraction)
        errors[record.path] = nil
    }

    private func end(_ record: AlbumRecord, error: (any Error)? = nil) {
        activity[record.path] = nil
        if let error { errors[record.path] = error.localizedDescription }
        try? record.modelContext?.save()
    }

    // MARK: TOC

    // Probes the disc's file(s) for their exact length and derives the TOC.
    // Only the first disc of a multi-disc set is handled for now.
    func computeTOC(_ record: AlbumRecord, locator: FFmpegLocator) async {
        guard let tool = Self.tool(locator), let disc = record.detected?.discs.first, let cue = disc.cue else { return }
        begin(record, String(localized: "Reading disc layout…"))
        do {
            var frames: [Int] = []
            for file in cue.files {
                let url = file.url(relativeTo: disc.folder)
                let info = try await tool.probe(url)
                let samples = try await Self.exactSampleCount(url, info: info, tool: tool)
                let spf = info.sampleRate / CueTime.framesPerSecond
                guard spf > 0, samples % Int64(spf) == 0 else {
                    throw DiscTOC.TOCError.noAudioTracks
                }
                frames.append(Int(samples / Int64(spf)))
            }
            record.toc = try DiscTOC(cue: cue, fileFrames: frames)
            end(record)
        } catch {
            end(record, error: error)
        }
    }

    // FLAC and DSF headers carry the exact sample count; other formats are
    // decoded once (their length is what the splitter will see anyway).
    private static func exactSampleCount(_ url: URL, info: FFmpegTool.StreamInfo, tool: FFmpegTool) async throws -> Int64 {
        if url.pathExtension.lowercased() == "flac", let flac = try? FLACFile(url: url) {
            return Int64(flac.streamInfo.totalSamples)
        }
        let format = try info.pcmFormat
        let (_, samples) = try await tool.rawChecksum(url, format: format)
        return samples
    }

    // MARK: CUETools DB

    func checkCUEToolsDB(_ record: AlbumRecord, locator: FFmpegLocator) async {
        if record.toc == nil {
            await computeTOC(record, locator: locator)
        }
        guard let toc = record.toc else { return }
        begin(record, String(localized: "Asking CUETools DB…"))
        do {
            let client = CUEToolsDBClient(userAgent: Self.userAgent)
            let response = try await client.lookup(toc: toc.ctdbTOCString)
            var verification: CUEToolsDBClient.Verification? = nil
            if let outcome = record.splitOutcome, let crcs = outcome.ctdbTrackCRC32s {
                verification = CUEToolsDBClient.verify(trackCRC32s: crcs, discCRC32: outcome.ctdbDiscCRC32, response: response)
            }
            record.ctdbReport = CTDBReport(
                checkedAt: Date(),
                entryCount: response.entries.count,
                totalConfidence: response.totalConfidence,
                bestConfidence: response.bestEntry?.confidence ?? 0,
                metadata: response.metadata,
                verification: verification
            )
            end(record)
        } catch {
            end(record, error: error)
        }
    }

    // MARK: Split

    func split(_ record: AlbumRecord, into destination: URL, locator: FFmpegLocator, options: SplitOptions = SplitOptions(), trashOriginals: Bool = false) async {
        guard let tool = Self.tool(locator) else {
            errors[record.path] = FFmpegLocator.LocateError.notFound.localizedDescription
            return
        }
        guard let detected = record.detected else { return }
        let discs = detected.discs.filter { $0.cue != nil }.sorted { $0.number < $1.number }
        guard !discs.isEmpty else { return }
        begin(record, String(localized: "Preparing…"), fraction: 0)
        record.state = .applying
        let path = record.path
        var outcomes: [SplitOutcome] = []
        do {
            let multi = discs.count > 1
            for (i, disc) in discs.enumerated() {
                guard let cue = disc.cue else { continue }
                let context = ProvisionalTags.AlbumContext.from(
                    cue: cue,
                    discNumber: multi ? disc.number : record.setPosition,
                    discTotal: multi ? discs.count : record.setTotal,
                    toc: i == 0 ? record.toc : nil
                )
                var opts = options
                // Members of a set share the album folder named after the set.
                if record.setID != nil, let title = record.setTitle {
                    let base = PathTemplate.render(options.albumFolderTemplate, values: [
                        "albumartist": record.artistHint ?? cue.performer ?? "Unknown Artist",
                        "album": title,
                        "year": record.yearHint ?? "",
                    ], ascii: options.asciiFileNames)
                    opts.albumFolderOverride = base + "/Disc \(record.setPosition ?? 1)"
                }
                let label = multi ? String(localized: "Disc \(disc.number): ") : ""
                let splitter = ImageSplitter(tool: tool)
                let outcome = try await splitter.split(disc: disc, album: context, destinationRoot: destination, options: opts) { [weak self] progress in
                    Task { @MainActor in
                        self?.activity[path] = Activity(message: label + Self.describe(progress.phase), fraction: (Double(i) + progress.fraction) / Double(discs.count))
                    }
                }
                outcomes.append(outcome)
            }
            record.splitOutcomes = outcomes
            if record.toc == nil { record.toc = outcomes.first?.toc }
            let verified = outcomes.allSatisfy(\.verified)
            record.state = verified ? .scanned : .error
            if !verified {
                record.errorMessage = outcomes.flatMap(\.warnings).joined(separator: "\n")
            }
            if verified, trashOriginals {
                // Only after a byte-verified split: the images and their CUEs go to the Trash.
                let originals = discs.flatMap { [$0.imageFile?.url, $0.cueURL] }.compactMap { $0 }
                Self.trash(originals, record: record)
            }
            end(record)
            // A fresh split has CRCs to compare, so refresh the CTDB verdict.
            if outcomes.first?.ctdbTrackCRC32s != nil {
                await checkCUEToolsDB(record, locator: locator)
            }
        } catch {
            if !outcomes.isEmpty { record.splitOutcomes = outcomes }
            record.state = .error
            record.errorMessage = error.localizedDescription
            end(record, error: error)
        }
    }

    // MARK: SACD

    // Extracts the stereo area (and the multichannel one when asked) of a
    // SACD image into DSF files under the destination root.
    func extractSACD(_ record: AlbumRecord, into destination: URL, multichannel: Bool, options: SACDExtractOptions = SACDExtractOptions(), trashOriginals: Bool = false) async {
        guard record.kind == .sacdISO else { return }
        begin(record, String(localized: "Reading disc…"), fraction: 0)
        record.state = .applying
        let path = record.path
        let url = record.url
        var options = options
        // Members of a set share the album folder named after the set.
        if record.setID != nil, let sacd = record.detected?.sacd {
            let base = PathTemplate.render(options.albumFolderTemplate, values: [
                "albumartist": sacd.albumArtist ?? record.artistHint ?? "Unknown Artist",
                "album": sacd.albumTitle ?? record.setTitle ?? record.displayTitle,
                "year": record.yearHint ?? "",
            ], ascii: options.asciiFileNames)
            options.albumFolderOverride = base + "/Disc \(record.setPosition ?? sacd.albumSequenceNumber)"
        }
        do {
            let disc = try await Task.detached(priority: .userInitiated) { try SACDDiscReader.read(url: url) }.value
            var areas: [SACDArea] = []
            if let stereo = disc.stereoArea { areas.append(stereo) }
            if multichannel, let mc = disc.multichannelArea { areas.append(mc) }
            var outcomes: [SACDExtractOutcome] = []
            for area in areas {
                let label = area.displayName
                let outcome = try await Task.detached(priority: .userInitiated) { [weak self] in
                    try SACDExtractor().extract(disc: disc, area: area, destinationRoot: destination, options: options) { p in
                        Task { @MainActor in
                            self?.activity[path] = Activity(message: "\(label): \(p.message)", fraction: p.fraction)
                        }
                    }
                }.value
                outcomes.append(outcome)
            }
            record.sacdOutcomes = outcomes
            let ok = outcomes.allSatisfy(\.verified)
            record.state = ok ? .scanned : .error
            record.errorMessage = ok ? nil : outcomes.flatMap(\.warnings).joined(separator: "\n")
            if ok, trashOriginals { Self.trash([url], record: record) }
            end(record)
        } catch {
            record.state = .error
            record.errorMessage = error.localizedDescription
            end(record, error: error)
        }
    }

    // Moves files to the Trash; a failure is reported on the record, never fatal.
    private static func trash(_ urls: [URL], record: AlbumRecord) {
        var problems: [String] = []
        for url in urls {
            do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
            catch { problems.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        if !problems.isEmpty { record.errorMessage = String(localized: "Could not move originals to the Trash: ") + problems.joined(separator: "; ") }
    }

    private static func describe(_ phase: SplitProgress.Phase) -> String {
        switch phase {
        case .probing: return String(localized: "Probing image…")
        case .decoding(let f, let of): return of > 1 ? String(localized: "Decoding file \(f) of \(of)…") : String(localized: "Decoding image…")
        case .encoding(let t, let of): return String(localized: "Encoding track \(t) of \(of)…")
        case .verifying: return String(localized: "Verifying…")
        case .finished: return String(localized: "Done")
        }
    }

    private static func tool(_ locator: FFmpegLocator) -> FFmpegTool? {
        guard let location = locator.locate(), let probe = location.ffprobe else { return nil }
        return FFmpegTool(ffmpeg: location.ffmpeg, ffprobe: probe)
    }
}
