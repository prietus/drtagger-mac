import Foundation
import Testing
@testable import LoudnessKit
import SplitKit

enum Signals {
    // Interleaved stereo sine at `dbfs` per channel.
    static func sine(hz: Double, dbfs: Double, seconds: Double, rate: Int, channels: Int = 2) -> [Float] {
        let amp = Float(pow(10, dbfs / 20))
        let n = Int(seconds * Double(rate))
        var out = [Float](repeating: 0, count: n * channels)
        for i in 0..<n {
            let v = amp * Float(sin(2 * .pi * hz * Double(i) / Double(rate)))
            for c in 0..<channels { out[i * channels + c] = v }
        }
        return out
    }

    static func measure(_ samples: [Float], rate: Int, channels: Int = 2) -> LoudnessResult {
        let m = R128Meter(sampleRate: rate, channels: channels)
        samples.withUnsafeBufferPointer { m.process($0) }
        return m.finish()
    }

    static func wav(_ samples: [Float], rate: Int, channels: Int = 2) -> Data {
        var pcm = Data(capacity: samples.count * 2)
        for s in samples { var v = Int16(max(-32768, min(32767, (s * 32767).rounded()))).littleEndian; withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) } }
        var d = Data("RIFF".utf8); d.append(u32(UInt32(36 + pcm.count))); d.append(Data("WAVE".utf8))
        d.append(Data("fmt ".utf8)); d.append(u32(16)); d.append(contentsOf: [1, 0, UInt8(channels), 0]); d.append(u32(UInt32(rate))); d.append(u32(UInt32(rate * 2 * channels))); d.append(contentsOf: [UInt8(2 * channels), 0, 16, 0])
        d.append(Data("data".utf8)); d.append(u32(UInt32(pcm.count))); d.append(pcm)
        return d
    }

    static func u32(_ v: UInt32) -> Data { var x = v.littleEndian; return withUnsafeBytes(of: &x) { Data($0) } }

    static var ffmpeg: FFmpegTool? {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u = u.deletingLastPathComponent() }
        let f = u.appending(path: "Vendor/ffmpeg/ffmpeg"), p = u.appending(path: "Vendor/ffmpeg/ffprobe")
        guard FileManager.default.isExecutableFile(atPath: f.path) else { return nil }
        return FFmpegTool(ffmpeg: f, ffprobe: p)
    }

    // ffmpeg's own meter, for cross-checking: (integrated LUFS, true peak dBTP).
    static func ffmpegR128(_ tool: FFmpegTool, _ url: URL) throws -> (Double, Double)? {
        let p = Process(); p.executableURL = tool.ffmpeg
        p.arguments = ["-nostats", "-i", url.path, "-af", "ebur128=peak=true", "-f", "null", "-"]
        let err = Pipe(); p.standardError = err; p.standardOutput = FileHandle.nullDevice
        try p.run(); let data = err.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard let summary = text.components(separatedBy: "Summary:").last else { return nil }
        func value(after label: String) -> Double? {
            guard let r = summary.range(of: label) else { return nil }
            let rest = summary[r.upperBound...].trimmingCharacters(in: .whitespaces)
            return Double(rest.split(separator: " ").first ?? "")
        }
        guard let i = value(after: "I:"), let peak = value(after: "Peak:") else { return nil }
        return (i, peak)
    }
}

@Suite("R128 meter") struct MeterTests {
    @Test(arguments: [48000, 44100, 96000])
    func ebuCalibrationTone(rate: Int) {
        // EBU Tech 3341 case 1: stereo 997 Hz at -23 dBFS reads -23.0 LUFS ±0.1.
        let r = Signals.measure(Signals.sine(hz: 997, dbfs: -23, seconds: 5, rate: rate), rate: rate)
        #expect(abs((r.integratedLUFS ?? 0) - (-23.0)) < 0.1, "rate \(rate): \(r.integratedLUFS ?? .nan)")
        #expect(abs(r.truePeakDBTP - (-23.0)) < 0.1, "true peak \(r.truePeakDBTP)")
        #expect(abs(r.samplePeakDBFS - (-23.0)) < 0.1)
        #expect(abs(r.durationSeconds - 5) < 0.01)
    }

    @Test func relativeGateDropsQuietPassages() {
        // EBU Tech 3341 case 3-ish: -36 dBFS for 10 s around 20 s of -23 dBFS → -23.0 ±0.1.
        let rate = 48000
        var s = Signals.sine(hz: 997, dbfs: -36, seconds: 10, rate: rate)
        s += Signals.sine(hz: 997, dbfs: -23, seconds: 20, rate: rate)
        s += Signals.sine(hz: 997, dbfs: -36, seconds: 10, rate: rate)
        let r = Signals.measure(s, rate: rate)
        #expect(abs((r.integratedLUFS ?? 0) - (-23.0)) < 0.1, "\(r.integratedLUFS ?? .nan)")
        #expect(Signals.measure([Float](repeating: 0, count: rate * 2), rate: rate).integratedLUFS == nil, "silence is gated out")
    }

    @Test func albumGatingAndTags() {
        let rate = 48000
        let loud = Signals.measure(Signals.sine(hz: 997, dbfs: -20, seconds: 4, rate: rate), rate: rate)
        let quiet = Signals.measure(Signals.sine(hz: 997, dbfs: -26, seconds: 4, rate: rate), rate: rate)
        let album = AlbumLoudness(tracks: [loud, quiet])
        let lufs = album.integratedLUFS ?? 0
        #expect(lufs > -26 && lufs < -20 && abs(lufs - (-22.2)) < 0.3, "album \(lufs)")   // power mean of -20 and -26
        #expect(abs(album.truePeakDBTP - (-20)) < 0.1)
        let tags = ReplayGain.tags(track: quiet, album: album, dsd: true)
        let dict = Dictionary(uniqueKeysWithValues: tags)
        #expect(dict["REPLAYGAIN_TRACK_GAIN"] == "8.00 dB")
        #expect(dict["REPLAYGAIN_TRACK_PEAK"].flatMap(Double.init).map { abs($0 - 0.0501187) < 0.0005 } == true)
        #expect(dict["R128_TRACK_GAIN"] == "768")            // (-23 - -26) * 256
        #expect(dict["REPLAYGAIN_ALBUM_GAIN"]?.hasSuffix(" dB") == true)
        #expect(dict["REPLAYGAIN_REFERENCE_LOUDNESS"] == "-18.00 LUFS")
    }

    @Test func fiveDotOneWeightsIgnoreLFE() {
        // LFE-only signal contributes nothing; surrounds count 1.41.
        let rate = 48000, n = rate * 3
        var lfe = [Float](repeating: 0, count: n * 6)
        for i in 0..<n { lfe[i * 6 + 3] = 0.5 * Float(sin(2 * .pi * 60 * Double(i) / Double(rate))) }
        #expect(Signals.measure(lfe, rate: rate, channels: 6).integratedLUFS == nil)
    }
}

@Suite("Analyzer vs ffmpeg", .serialized) struct AnalyzerTests {
    @Test func matchesFFmpegEBUR128() async throws {
        guard let tool = Signals.ffmpeg else { return }
        let rate = 44100
        var s = Signals.sine(hz: 997, dbfs: -23, seconds: 6, rate: rate)
        s += Signals.sine(hz: 3000, dbfs: -14, seconds: 3, rate: rate)      // shelf region: K-weighting matters
        s += Signals.sine(hz: 60, dbfs: -30, seconds: 3, rate: rate)        // high-pass region
        let dir = FileManager.default.temporaryDirectory.appending(path: "LoudnessKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appending(path: "t.wav")
        try Signals.wav(s, rate: rate).write(to: wav)

        let ours = try await LoudnessAnalyzer(tool: tool).analyze(wav)
        guard let (theirs, theirPeak) = try Signals.ffmpegR128(tool, wav) else { return }
        #expect(abs((ours.integratedLUFS ?? 0) - theirs) < 0.15, "ours \(ours.integratedLUFS ?? .nan) vs ffmpeg \(theirs)")
        #expect(abs(ours.truePeakDBTP - theirPeak) < 0.2, "peak ours \(ours.truePeakDBTP) vs ffmpeg \(theirPeak)")

        let album = try await LoudnessAnalyzer(tool: tool).analyzeAlbum([wav, wav])
        #expect(album.tracks.count == 2 && abs((album.integratedLUFS ?? 0) - theirs) < 0.15)
    }
}
