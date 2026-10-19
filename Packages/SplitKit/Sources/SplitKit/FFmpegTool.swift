import CryptoKit
import Foundation
import LibraryKit

// Drives the ffmpeg / ffprobe executables for decoding and encoding.
// Every call spawns one process; stdin feeding (for encoding a byte range)
// happens on a background thread so pipes never deadlock, and task
// cancellation terminates the child.
public struct FFmpegTool: Sendable {

    public enum ToolError: LocalizedError, Equatable {
        case launchFailed(String)
        case failed(command: String, status: Int32, stderr: String)
        case badProbeOutput(String)
        case noAudioStream(URL)
        case outputMisaligned(bytes: Int64, bytesPerFrame: Int)

        public var errorDescription: String? {
            switch self {
            case .launchFailed(let m): return "Could not launch ffmpeg: \(m)"
            case .failed(let cmd, let status, let err):
                let tail = err.split(separator: "\n").suffix(3).joined(separator: " ")
                return "\(cmd) failed (exit \(status)): \(tail)"
            case .badProbeOutput(let m): return "ffprobe output could not be parsed: \(m)"
            case .noAudioStream(let u): return "\(u.lastPathComponent) has no audio stream."
            case .outputMisaligned(let b, let f): return "Decoded \(b) bytes, not a multiple of \(f) bytes per frame."
            }
        }
    }

    public struct StreamInfo: Sendable, Equatable, Codable {
        public let codec: String
        public let sampleRate: Int
        public let channels: Int
        public let bitsPerSample: Int
        public let durationSeconds: Double?

        public var pcmFormat: PCMFormat {
            get throws {
                let bits: Int
                switch bitsPerSample {
                case 0...16: bits = 16
                case 17...24: bits = 24
                default: bits = 32
                }
                return try PCMFormat(sampleRate: sampleRate, channels: channels, bitsPerSample: bits)
            }
        }
    }

    public struct FeedDigest: Sendable, Equatable {
        public let byteCount: Int64
        public let md5: Data
        public let crc32: UInt32

        public var md5Hex: String { md5.map { String(format: "%02x", $0) }.joined() }
    }

    public let ffmpeg: URL
    public let ffprobe: URL

    public init(ffmpeg: URL, ffprobe: URL) {
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
    }

    // MARK: Probe

    public func probe(_ url: URL) async throws -> StreamInfo {
        let args = [
            "-v", "error", "-select_streams", "a:0",
            "-show_entries", "stream=codec_name,sample_rate,channels,bits_per_sample,bits_per_raw_sample,duration",
            "-of", "json", url.path,
        ]
        let result = try await ProcessLauncher.run(ffprobe, arguments: args)
        guard result.status == 0 else {
            throw ToolError.failed(command: "ffprobe", status: result.status, stderr: result.stderrText)
        }
        return try Self.parseProbe(result.stdout, url: url)
    }

    static func parseProbe(_ data: Data, url: URL) throws -> StreamInfo {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = root["streams"] as? [[String: Any]] else {
            throw ToolError.badProbeOutput(String(decoding: data.prefix(200), as: UTF8.self))
        }
        guard let s = streams.first else { throw ToolError.noAudioStream(url) }
        func int(_ key: String) -> Int? {
            if let v = s[key] as? Int { return v }
            if let v = s[key] as? String { return Int(v) }
            return nil
        }
        func double(_ key: String) -> Double? {
            if let v = s[key] as? Double { return v }
            if let v = s[key] as? String { return Double(v) }
            return nil
        }
        guard let rate = int("sample_rate"), rate > 0, let channels = int("channels"), channels > 0 else {
            throw ToolError.badProbeOutput("missing sample_rate / channels")
        }
        let raw = int("bits_per_raw_sample") ?? 0
        let bps = int("bits_per_sample") ?? 0
        let bits = raw > 0 ? raw : (bps > 0 ? bps : 16)
        return StreamInfo(
            codec: s["codec_name"] as? String ?? "",
            sampleRate: rate,
            channels: channels,
            bitsPerSample: bits,
            durationSeconds: double("duration")
        )
    }

    // MARK: Tags

    // Container tags as ffprobe reports them (format-level plus the first
    // audio stream's), keys upper-cased. Works for FLAC, APE, WavPack, TTA,
    // ALAC, DSF and WAV alike.
    public func probeTags(_ url: URL) async throws -> [String: String] {
        let args = [
            "-v", "error", "-select_streams", "a:0",
            "-show_entries", "format_tags:stream_tags",
            "-of", "json", url.path,
        ]
        let result = try await ProcessLauncher.run(ffprobe, arguments: args)
        guard result.status == 0 else {
            throw ToolError.failed(command: "ffprobe tags", status: result.status, stderr: result.stderrText)
        }
        guard let root = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else {
            throw ToolError.badProbeOutput("tags")
        }
        var tags: [String: String] = [:]
        if let streams = root["streams"] as? [[String: Any]], let st = streams.first?["tags"] as? [String: Any] {
            for (k, v) in st { tags[k.uppercased()] = "\(v)" }
        }
        if let format = root["format"] as? [String: Any], let ft = format["tags"] as? [String: Any] {
            for (k, v) in ft { tags[k.uppercased()] = "\(v)" }
        }
        return tags
    }

    // Decodes `seconds` of audio from `start` into 16-bit interleaved PCM
    // at the source rate (down-mixed to at most two channels), the input
    // chromaprint expects. Returns samples per channel and the rate.
    public func decodeSnippet(_ url: URL, start: Double = 0, seconds: Double = 120) async throws -> (samples: [Int16], sampleRate: Int, channels: Int) {
        let info = try await probe(url)
        let channels = min(2, max(1, info.channels))
        var args = ["-v", "error", "-nostdin"]
        if start > 0 { args += ["-ss", String(format: "%.3f", start)] }
        args += [
            "-i", url.path,
            "-t", String(format: "%.3f", seconds),
            "-map", "0:a:0", "-vn",
            "-ac", String(channels),
            "-f", "s16le", "-acodec", "pcm_s16le",
            "pipe:1",
        ]
        let result = try await ProcessLauncher.run(ffmpeg, arguments: args)
        guard result.status == 0 else {
            throw ToolError.failed(command: "ffmpeg snippet", status: result.status, stderr: result.stderrText)
        }
        let count = result.stdout.count / 2
        var samples = [Int16](repeating: 0, count: count)
        _ = samples.withUnsafeMutableBytes { result.stdout.copyBytes(to: $0, count: count * 2) }
        return (samples, info.sampleRate, channels)
    }

    // MARK: Decode

    // Decodes the whole file to raw interleaved PCM. Returns the sample
    // (frame) count.
    public func decodeToRaw(_ url: URL, format: PCMFormat, to output: URL) async throws -> Int64 {
        let args = [
            "-v", "error", "-nostdin", "-y",
            "-i", url.path,
            "-map", "0:a:0", "-vn",
            "-f", format.ffmpegFormatName,
            "-acodec", format.ffmpegCodecName,
            "-ar", String(format.sampleRate),
            "-ac", String(format.channels),
            output.path,
        ]
        let result = try await ProcessLauncher.run(ffmpeg, arguments: args)
        guard result.status == 0 else {
            throw ToolError.failed(command: "ffmpeg decode", status: result.status, stderr: result.stderrText)
        }
        let size = Int64((try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.int64Value ?? 0)
        guard size % Int64(format.bytesPerFrame) == 0 else {
            throw ToolError.outputMisaligned(bytes: size, bytesPerFrame: format.bytesPerFrame)
        }
        return size / Int64(format.bytesPerFrame)
    }

    // Decodes the whole file to raw interleaved PCM and hands it over in
    // chunks as ffmpeg produces it: nothing goes to disk (a DSD album
    // decoded to files is gigabytes). ffmpeg runs at utility priority.
    // Returns the byte count.
    @discardableResult
    public func decodeStreaming(_ url: URL, format: PCMFormat, consume: @escaping @Sendable (Data) throws -> Void) async throws -> Int64 {
        let args = [
            "-v", "error", "-nostdin",
            "-i", url.path,
            "-map", "0:a:0", "-vn",
            "-f", format.ffmpegFormatName,
            "-acodec", format.ffmpegCodecName,
            "-ar", String(format.sampleRate),
            "-ac", String(format.channels),
            "pipe:1",
        ]
        let (status, bytes, stderr) = try await ProcessLauncher.stream(ffmpeg, arguments: args, consume: consume)
        guard status == 0 else {
            throw ToolError.failed(command: "ffmpeg decode", status: status, stderr: stderr)
        }
        return bytes
    }

    // MARK: Encode

    // Encodes a byte range of a raw PCM file to FLAC, feeding ffmpeg's stdin.
    // The digest covers exactly the bytes fed, so it can be compared with the
    // STREAMINFO MD5 the encoder writes.
    public func encodeFLAC(
        rawPCM: URL,
        byteRange: Range<Int64>,
        format: PCMFormat,
        compressionLevel: Int,
        to output: URL
    ) async throws -> FeedDigest {
        let args = [
            "-v", "error", "-y",
            "-f", format.ffmpegFormatName,
            "-ar", String(format.sampleRate),
            "-ac", String(format.channels),
            "-i", "pipe:0",
            "-map", "0:a:0",
            "-c:a", "flac",
            "-compression_level", String(max(0, min(12, compressionLevel))),
            "-f", "flac",
            output.path,
        ]
        let box = DigestBox()
        let result = try await ProcessLauncher.run(ffmpeg, arguments: args) { stdin in
            let handle = try FileHandle(forReadingFrom: rawPCM)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(byteRange.lowerBound))
            var remaining = byteRange.upperBound - byteRange.lowerBound
            var md5 = Insecure.MD5()
            var crc = CRC32()
            var fed: Int64 = 0
            while remaining > 0 {
                let n = Int(min(Int64(1 << 20), remaining))
                guard let chunk = try handle.read(upToCount: n), !chunk.isEmpty else { break }
                md5.update(data: chunk)
                crc.update(chunk)
                try stdin.write(contentsOf: chunk)
                fed += Int64(chunk.count)
                remaining -= Int64(chunk.count)
            }
            box.set(FeedDigest(byteCount: fed, md5: Data(md5.finalize()), crc32: crc.value))
        }
        guard result.status == 0 else {
            throw ToolError.failed(command: "ffmpeg flac", status: result.status, stderr: result.stderrText)
        }
        guard let digest = box.get() else {
            throw ToolError.failed(command: "ffmpeg flac", status: -1, stderr: "stdin feeder produced no digest")
        }
        return digest
    }

    // Decodes any audio file and returns the CRC32 + sample count of its raw
    // PCM in `format`. Used as the fallback verification for encoded tracks.
    public func rawChecksum(_ url: URL, format: PCMFormat) async throws -> (crc32: UInt32, samples: Int64) {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "drtagger-verify-\(UUID().uuidString).raw")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let samples = try await decodeToRaw(url, format: format, to: tmp)
        let crc = try CRC32.checksum(fileAt: tmp, range: 0..<(samples * Int64(format.bytesPerFrame)))
        return (crc, samples)
    }

    private final class DigestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var digest: FeedDigest?
        func set(_ d: FeedDigest) { lock.lock(); digest = d; lock.unlock() }
        func get() -> FeedDigest? { lock.lock(); defer { lock.unlock() }; return digest }
    }
}

// MARK: - Process launching

enum ProcessLauncher {

    struct Result: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: Data
        var stderrText: String { String(decoding: stderr, as: UTF8.self) }
    }

    typealias StdinFeeder = @Sendable (FileHandle) throws -> Void

    static func run(_ executable: URL, arguments: [String], stdin feeder: StdinFeeder? = nil) async throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments.map(ProcessPaths.argument)

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe: Pipe? = feeder != nil ? Pipe() : nil
        process.standardInput = inPipe ?? FileHandle.nullDevice

        let collector = Collector()
        outPipe.fileHandleForReading.readabilityHandler = { h in collector.append(h.availableData, err: false) }
        errPipe.fileHandleForReading.readabilityHandler = { h in collector.append(h.availableData, err: true) }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Result, any Error>) in
                process.terminationHandler = { proc in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    collector.append(outPipe.fileHandleForReading.readDataToEndOfFile(), err: false)
                    collector.append(errPipe.fileHandleForReading.readDataToEndOfFile(), err: true)
                    let (out, err) = collector.snapshot()
                    if let feedError = collector.feedError {
                        continuation.resume(throwing: feedError)
                    } else {
                        continuation.resume(returning: Result(status: proc.terminationStatus, stdout: out, stderr: err))
                    }
                }
                do {
                    try process.run()
                } catch {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: FFmpegTool.ToolError.launchFailed(error.localizedDescription))
                    return
                }
                if let feeder, let inPipe {
                    let writer = inPipe.fileHandleForWriting
                    Thread.detachNewThread {
                        do {
                            try feeder(writer)
                        } catch {
                            // EPIPE when ffmpeg exits early is reported through
                            // the exit status; keep the first real error.
                            collector.setFeedError(error)
                        }
                        try? writer.close()
                    }
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    // stdout read in chunks on a background queue and handed to `consume`;
    // a throwing consumer stops the process.
    static func stream(_ executable: URL, arguments: [String], chunkBytes: Int = 1 << 20,
                       consume: @escaping @Sendable (Data) throws -> Void) async throws -> (status: Int32, bytes: Int64, stderr: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments.map(ProcessPaths.argument)
        process.qualityOfService = .utility
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        let collector = Collector()
        errPipe.fileHandleForReading.readabilityHandler = { h in collector.append(h.availableData, err: true) }
        do {
            try process.run()
        } catch {
            errPipe.fileHandleForReading.readabilityHandler = nil
            throw FFmpegTool.ToolError.launchFailed(error.localizedDescription)
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(status: Int32, bytes: Int64, stderr: String), any Error>) in
                DispatchQueue.global(qos: .utility).async {
                    let reader = outPipe.fileHandleForReading
                    var bytes: Int64 = 0
                    var failure: (any Error)?
                    while let data = try? reader.read(upToCount: chunkBytes), !data.isEmpty {
                        guard failure == nil else { continue }   // drain so ffmpeg can exit
                        bytes += Int64(data.count)
                        do { try consume(data) } catch { failure = error; process.terminate() }
                    }
                    process.waitUntilExit()
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    collector.append(errPipe.fileHandleForReading.readDataToEndOfFile(), err: true)
                    if let failure { continuation.resume(throwing: failure); return }
                    let stderr = String(decoding: collector.snapshot().1, as: UTF8.self)
                    continuation.resume(returning: (process.terminationStatus, bytes, stderr))
                }
            }
        } onCancel: {
            process.terminate()
        }
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data()
        private var err = Data()
        private var _feedError: (any Error)?

        var feedError: (any Error)? { lock.lock(); defer { lock.unlock() }; return _feedError }

        func append(_ data: Data, err isErr: Bool) {
            guard !data.isEmpty else { return }
            lock.lock()
            if isErr { err.append(data) } else { out.append(data) }
            lock.unlock()
        }

        func setFeedError(_ e: any Error) {
            lock.lock()
            if _feedError == nil { _feedError = e }
            lock.unlock()
        }

        func snapshot() -> (Data, Data) {
            lock.lock(); defer { lock.unlock() }
            return (out, err)
        }
    }
}
