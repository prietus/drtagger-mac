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

    func split(_ record: AlbumRecord, into destination: URL, locator: FFmpegLocator, options: SplitOptions = SplitOptions()) async {
        guard let tool = Self.tool(locator) else {
            errors[record.path] = FFmpegLocator.LocateError.notFound.localizedDescription
            return
        }
        guard let detected = record.detected, let disc = detected.discs.first, let cue = disc.cue else { return }
        begin(record, String(localized: "Preparing…"), fraction: 0)
        record.state = .applying
        let path = record.path
        do {
            let context = ProvisionalTags.AlbumContext.from(
                cue: cue,
                discNumber: detected.discs.count > 1 ? disc.number : nil,
                discTotal: detected.discs.count > 1 ? detected.discs.count : nil,
                toc: record.toc
            )
            let splitter = ImageSplitter(tool: tool)
            let outcome = try await splitter.split(disc: disc, album: context, destinationRoot: destination, options: options) { [weak self] progress in
                Task { @MainActor in
                    self?.activity[path] = Activity(message: Self.describe(progress.phase), fraction: progress.fraction)
                }
            }
            record.splitOutcome = outcome
            if record.toc == nil { record.toc = outcome.toc }
            record.state = outcome.verified ? .scanned : .error
            if !outcome.verified {
                record.errorMessage = outcome.warnings.joined(separator: "\n")
            }
            end(record)
            // A fresh split has CRCs to compare, so refresh the CTDB verdict.
            if outcome.ctdbTrackCRC32s != nil {
                await checkCUEToolsDB(record, locator: locator)
            }
        } catch {
            record.state = .error
            record.errorMessage = error.localizedDescription
            end(record, error: error)
        }
    }

    // MARK: SACD

    // Extracts the stereo area (and the multichannel one when asked) of a
    // SACD image into DSF files under the destination root.
    func extractSACD(_ record: AlbumRecord, into destination: URL, multichannel: Bool, options: SACDExtractOptions = SACDExtractOptions()) async {
        guard record.kind == .sacdISO else { return }
        begin(record, String(localized: "Reading disc…"), fraction: 0)
        record.state = .applying
        let path = record.path
        let url = record.url
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
            end(record)
        } catch {
            record.state = .error
            record.errorMessage = error.localizedDescription
            end(record, error: error)
        }
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
