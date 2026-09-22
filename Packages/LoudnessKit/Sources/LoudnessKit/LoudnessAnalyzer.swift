import Foundation
import SplitKit

// Decodes a file with ffmpeg to 32-bit PCM in a temporary file and runs
// the meter over it in chunks. DSD (and anything above 192 kHz) is
// resampled to 88.2 kHz first: the K filters are specified for audio
// rates and the peak of a DSD stream is meaningless before the low-pass.
public actor LoudnessAnalyzer {

    public let tool: FFmpegTool
    public var maxConcurrent = 2

    public init(tool: FFmpegTool) {
        self.tool = tool
    }

    public func analyze(_ url: URL) async throws -> LoudnessResult {
        let info = try await tool.probe(url)
        let isDSD = info.codec.lowercased().hasPrefix("dsd") || info.sampleRate > 192_000
        let rate = isDSD ? 88_200 : info.sampleRate
        let channels = min(8, max(1, info.channels))
        let format = try PCMFormat(sampleRate: rate, channels: channels, bitsPerSample: 32)
        let tmp = FileManager.default.temporaryDirectory.appending(path: "drtagger-loudness-\(UUID().uuidString).raw")
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try await tool.decodeToRaw(url, format: format, to: tmp)
        return try Self.measure(rawInt32: tmp, sampleRate: rate, channels: channels)
    }

    // Album loudness gates over every block of every track.
    public func analyzeAlbum(_ urls: [URL], progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> AlbumLoudness {
        var results = [LoudnessResult?](repeating: nil, count: urls.count)
        var done = 0
        try await withThrowingTaskGroup(of: (Int, LoudnessResult).self) { group in
            var next = 0
            func enqueue() {
                guard next < urls.count else { return }
                let i = next, url = urls[i]
                next += 1
                group.addTask { (i, try await self.analyze(url)) }
            }
            for _ in 0..<maxConcurrent { enqueue() }
            for try await (i, r) in group {
                results[i] = r
                done += 1
                progress(done, urls.count)
                enqueue()
            }
        }
        return AlbumLoudness(tracks: results.compactMap { $0 })
    }

    static func measure(rawInt32 url: URL, sampleRate: Int, channels: Int) throws -> LoudnessResult {
        let meter = R128Meter(sampleRate: sampleRate, channels: channels)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let frameBytes = 4 * channels
        let chunkFrames = 65_536
        var floats = [Float](repeating: 0, count: chunkFrames * channels)
        let scale = Float(1.0 / 2_147_483_648.0)
        while let data = try handle.read(upToCount: chunkFrames * frameBytes), !data.isEmpty {
            let count = data.count / 4
            data.withUnsafeBytes { raw in
                let ints = raw.bindMemory(to: Int32.self)
                for i in 0..<count { floats[i] = Float(Int32(littleEndian: ints[i])) * scale }
            }
            floats.withUnsafeBufferPointer { buf in
                meter.process(UnsafeBufferPointer(rebasing: buf[0..<count]))
            }
        }
        return meter.finish()
    }
}
