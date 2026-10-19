import Foundation
import SplitKit

// Decodes a file with ffmpeg to 32-bit PCM and runs the meter over the
// stream as it arrives (no temporary file). DSD (and anything above 192 kHz) is
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
        let stream = StreamMeter(sampleRate: rate, channels: channels)
        try await tool.decodeStreaming(url, format: format) { stream.feed($0) }
        return stream.finish()
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

    // Meters 32-bit little-endian PCM fed in arbitrary chunks; a partial
    // frame waits for the next chunk.
    final class StreamMeter: @unchecked Sendable {
        let meter: R128Meter
        let frameBytes: Int
        var carry = Data()
        var floats: [Float] = []
        static let scale = Float(1.0 / 2_147_483_648.0)

        init(sampleRate: Int, channels: Int) {
            meter = R128Meter(sampleRate: sampleRate, channels: channels)
            frameBytes = 4 * channels
        }

        func feed(_ data: Data) {
            carry.append(data)
            let usable = carry.count - carry.count % frameBytes
            guard usable > 0 else { return }
            let count = usable / 4
            if floats.count < count { floats = [Float](repeating: 0, count: count) }
            carry.withUnsafeBytes { raw in
                for i in 0..<count {
                    floats[i] = Float(Int32(littleEndian: raw.loadUnaligned(fromByteOffset: i * 4, as: Int32.self))) * Self.scale
                }
            }
            floats.withUnsafeBufferPointer { meter.process(UnsafeBufferPointer(rebasing: $0[0..<count])) }
            carry = Data(carry.suffix(from: carry.startIndex + usable))
        }

        func finish() -> LoudnessResult { meter.finish() }
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
