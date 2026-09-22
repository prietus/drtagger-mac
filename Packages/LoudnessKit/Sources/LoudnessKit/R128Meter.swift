import Accelerate
import Foundation

// Result of one measurement. Powers are linear mean squares of the
// K-weighted signal; loudness in LUFS is -0.691 + 10·log10(power).
public struct LoudnessResult: Sendable, Codable, Equatable {
    public let integratedLUFS: Double?     // nil when everything is gated out (silence)
    public let truePeakDBTP: Double        // -inf for silence encodes as -200
    public let samplePeakDBFS: Double
    public let blockPowers: [Double]       // 400 ms momentary blocks every 100 ms
    public let sampleRate: Int
    public let channels: Int
    public let durationSeconds: Double

    public init(integratedLUFS: Double?, truePeakDBTP: Double, samplePeakDBFS: Double, blockPowers: [Double], sampleRate: Int, channels: Int, durationSeconds: Double) {
        self.integratedLUFS = integratedLUFS
        self.truePeakDBTP = truePeakDBTP.isFinite ? truePeakDBTP : -200
        self.samplePeakDBFS = samplePeakDBFS.isFinite ? samplePeakDBFS : -200
        self.blockPowers = blockPowers
        self.sampleRate = sampleRate
        self.channels = channels
        self.durationSeconds = durationSeconds
    }
}

// ITU-R BS.1770-4 meter: K-weighting (two biquads, coefficients derived
// for any sample rate the way libebur128 does), 400 ms blocks with 75 %
// overlap, absolute (-70 LUFS) and relative (-10 LU) gates, sample peak
// and true peak by polyphase sinc interpolation (4× below 96 kHz, 2× below
// 192 kHz). Feed interleaved Float samples in any chunking. The heavy
// lifting (filters, convolutions, sums) runs in Accelerate so it is fast
// even in unoptimised builds.
public final class R128Meter {

    public let sampleRate: Int
    public let channels: Int

    private var biquads: [vDSP.Biquad<Double>]
    private let weights: [Double]

    private let subBlockFrames: Int
    private var subSum: [Double]
    private var subCount = 0
    private var subPowers: [Double] = []
    private var blockPowers: [Double] = []
    private var frames: Int64 = 0

    private var samplePeak: Float = 0
    private var truePeak: Float = 0
    private let oversample: Int
    private let phases: [[Float]]            // oversample × taps, reversed for vDSP_conv
    private let taps: Int
    private var history: [[Float]]           // per channel: the last taps-1 raw samples

    public init(sampleRate: Int, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
        let fs = Double(sampleRate)

        // Shelf then high-pass (libebur128 constants), one cascaded biquad per channel.
        let f1 = 1681.974450955533, g = 3.999843853973347, q1 = 0.7071752369554196
        let k1 = tan(.pi * f1 / fs)
        let vh = pow(10, g / 20), vb = pow(vh, 0.4996667741545416)
        let a01 = 1 + k1 / q1 + k1 * k1
        let shelf: [Double] = [(vh + vb * k1 / q1 + k1 * k1) / a01, 2 * (k1 * k1 - vh) / a01, (vh - vb * k1 / q1 + k1 * k1) / a01,
                               2 * (k1 * k1 - 1) / a01, (1 - k1 / q1 + k1 * k1) / a01]
        let f2 = 38.13547087602444, q2 = 0.5003270373238773
        let k2 = tan(.pi * f2 / fs)
        let a02 = 1 + k2 / q2 + k2 * k2
        // vDSP wants b0 b1 b2 a1 a2 per section. libebur128 keeps the
        // high-pass numerator at 1, -2, 1 (not divided by a0): that +0.04 dB
        // is part of the reference chain the -0.691 offset was fitted to.
        let hp: [Double] = [1, -2, 1, 2 * (k2 * k2 - 1) / a02, (1 - k2 / q2 + k2 * k2) / a02]
        biquads = (0..<channels).map { _ in vDSP.Biquad(coefficients: shelf + hp, channelCount: 1, sectionCount: 2, ofType: Double.self)! }

        // Channel weights: L R C 1.0, LFE 0 (5.1 / 7.1 layouts), surrounds 1.41.
        weights = (0..<channels).map { c in
            if channels >= 6 && c == 3 { return 0 }
            return (channels >= 4 && c >= 3) || (channels == 4 && c >= 2) ? 1.41 : 1.0
        }
        subBlockFrames = max(1, sampleRate / 10)
        subSum = Array(repeating: 0, count: channels)

        let factor = sampleRate < 96000 ? 4 : (sampleRate < 192000 ? 2 : 1)
        oversample = factor
        let tapsPerPhase = 12
        taps = tapsPerPhase
        var phases: [[Float]] = []
        if factor > 1 {
            let n = tapsPerPhase * factor
            let center = Double(n - 1) / 2
            let h = (0..<n).map { i -> Double in
                let x = (Double(i) - center) / Double(factor)
                let sinc = x == 0 ? 1.0 : sin(.pi * x) / (.pi * x)
                let window = 0.5 - 0.5 * cos(2 * .pi * Double(i) / Double(n - 1))
                return sinc * window
            }
            for p in 0..<factor {
                var phase = (0..<tapsPerPhase).map { k in h[p + factor * k] }
                let sum = phase.reduce(0, +)
                if sum != 0 { phase = phase.map { $0 / sum } }
                // y[n] = Σ_k phase[k] · x[n-k]: vDSP_conv correlates with the
                // filter as given over x[n+k], so store it reversed.
                phases.append(phase.reversed().map(Float.init))
            }
        }
        self.phases = phases
        history = Array(repeating: Array(repeating: 0, count: tapsPerPhase - 1), count: channels)
    }

    public func process(_ samples: UnsafeBufferPointer<Float>) {
        let frameCount = samples.count / channels
        guard frameCount > 0, let base = samples.baseAddress else { return }
        var chan = [Float](repeating: 0, count: frameCount)
        var filtered = [Double](repeating: 0, count: frameCount)
        var squared = [Double](repeating: 0, count: frameCount)
        var padded = [Float](repeating: 0, count: frameCount + taps - 1)
        var conv = [Float](repeating: 0, count: frameCount)
        // Per-channel squared sums land here, then the sub-block walk below
        // splits them at 100 ms boundaries.
        var squaredPerChannel: [[Double]] = []
        squaredPerChannel.reserveCapacity(channels)

        for c in 0..<channels {
            // Deinterleave.
            cblas_scopy(Int32(frameCount), base + c, Int32(channels), &chan, 1)
            // Sample peak.
            var peak: Float = 0
            vDSP_maxmgv(chan, 1, &peak, vDSP_Length(frameCount))
            if peak > samplePeak { samplePeak = peak }
            // True peak: interpolate each phase over history + chunk.
            if oversample > 1 {
                let hist = history[c]
                for i in 0..<(taps - 1) { padded[i] = hist[i] }
                for i in 0..<frameCount { padded[taps - 1 + i] = chan[i] }
                for phase in phases {
                    vDSP_conv(padded, 1, phase, 1, &conv, 1, vDSP_Length(frameCount), vDSP_Length(taps))
                    var p: Float = 0
                    vDSP_maxmgv(conv, 1, &p, vDSP_Length(frameCount))
                    if p > truePeak { truePeak = p }
                }
                if frameCount >= taps - 1 {
                    history[c] = Array(chan[(frameCount - (taps - 1))...])
                } else {
                    history[c] = Array((hist + chan).suffix(taps - 1))
                }
            }
            // K-weighting in double precision, then squares.
            vDSP_vspdp(chan, 1, &filtered, 1, vDSP_Length(frameCount))
            filtered = biquads[c].apply(input: filtered)
            vDSP_vsqD(filtered, 1, &squared, 1, vDSP_Length(frameCount))
            squaredPerChannel.append(squared)
        }

        // Sub-blocks of 100 ms across chunk boundaries.
        var offset = 0
        while offset < frameCount {
            let take = min(subBlockFrames - subCount, frameCount - offset)
            for c in 0..<channels {
                var sum = 0.0
                squaredPerChannel[c].withUnsafeBufferPointer { buf in
                    vDSP_sveD(buf.baseAddress! + offset, 1, &sum, vDSP_Length(take))
                }
                subSum[c] += sum
            }
            subCount += take
            offset += take
            if subCount == subBlockFrames { closeSubBlock() }
        }
        frames += Int64(frameCount)
    }

    private func closeSubBlock() {
        var power = 0.0
        for c in 0..<channels { power += weights[c] * subSum[c] / Double(subBlockFrames); subSum[c] = 0 }
        subPowers.append(power)
        subCount = 0
        if subPowers.count >= 4 {
            let n = subPowers.count
            blockPowers.append((subPowers[n - 1] + subPowers[n - 2] + subPowers[n - 3] + subPowers[n - 4]) / 4)
        }
    }

    public func finish() -> LoudnessResult {
        let peak = Double(oversample > 1 ? max(truePeak, samplePeak) : samplePeak)
        return LoudnessResult(
            integratedLUFS: Self.integrated(blockPowers: blockPowers),
            truePeakDBTP: 20 * log10(peak),
            samplePeakDBFS: 20 * log10(Double(samplePeak)),
            blockPowers: blockPowers,
            sampleRate: sampleRate, channels: channels,
            durationSeconds: Double(frames) / Double(sampleRate)
        )
    }

    public static func loudness(_ power: Double) -> Double { -0.691 + 10 * log10(power) }

    // Gated integration over any set of blocks: one track, or every block
    // of an album for the album loudness.
    public static func integrated(blockPowers: [Double]) -> Double? {
        let absoluteGate = blockPowers.filter { loudness($0) > -70 }
        guard !absoluteGate.isEmpty else { return nil }
        let relativeThreshold = loudness(absoluteGate.reduce(0, +) / Double(absoluteGate.count)) - 10
        let gated = absoluteGate.filter { loudness($0) > relativeThreshold }
        guard !gated.isEmpty else { return nil }
        return loudness(gated.reduce(0, +) / Double(gated.count))
    }
}
