import Foundation
import Chromaprint

// Swift wrapper around chromaprint's C API. The library wants a stream
// of 16-bit signed interleaved PCM samples and an explicit sample rate
// plus channel count on start; it resamples and mixes down internally
// (chromaprint's own chroma_resampler + AudioProcessor handle that, no
// libav needed). Output is the base64 fingerprint string that AcoustID
// expects in its `fingerprint` query parameter.
public actor Fingerprinter {

    public enum FingerprinterError: LocalizedError {
        case contextAllocationFailed
        case startFailed
        case feedFailed
        case finishFailed
        case getFingerprintFailed

        public var errorDescription: String? {
            switch self {
            case .contextAllocationFailed: return "Could not create chromaprint context."
            case .startFailed: return "chromaprint_start failed."
            case .feedFailed: return "chromaprint_feed failed."
            case .finishFailed: return "chromaprint_finish failed."
            case .getFingerprintFailed: return "chromaprint_get_fingerprint failed."
            }
        }
    }

    public struct Result: Sendable, Equatable {
        public let fingerprint: String   // base64, AcoustID-compatible
        public let durationSeconds: Int  // truncated to the integer second
        // Raw uint32 array — same as `fpcalc -raw` output. Populated
        // only when the caller requests it (debug / comparison use).
        public let rawFingerprint: [UInt32]

        public init(fingerprint: String, durationSeconds: Int, rawFingerprint: [UInt32] = []) {
            self.fingerprint = fingerprint
            self.durationSeconds = durationSeconds
            self.rawFingerprint = rawFingerprint
        }
    }

    public init() {}

    // Computes the fingerprint from a contiguous Int16 PCM buffer. The
    // buffer is expected to be interleaved (channel-interleaved) if
    // numChannels > 1 — chromaprint handles the downmix. `sampleRate`
    // is the source rate, not chromaprint's internal 11025 Hz rate.
    //
    // We take the samples as an Array<Int16> (Sendable) rather than an
    // UnsafeBufferPointer so callers don't have to worry about pointer
    // lifetime across the actor hop.
    public func fingerprint(
        samples: [Int16],
        sampleRate: Int,
        numChannels: Int,
        durationSeconds: Int
    ) throws -> Result {
        guard let ctx = chromaprint_new(Int32(CHROMAPRINT_ALGORITHM_DEFAULT.rawValue)) else {
            throw FingerprinterError.contextAllocationFailed
        }
        defer { chromaprint_free(ctx) }

        guard chromaprint_start(ctx, Int32(sampleRate), Int32(numChannels)) == 1 else {
            throw FingerprinterError.startFailed
        }

        // chromaprint_feed takes the sample count, not byte count, and
        // for stereo input that's (frames * channels). The array count
        // is already (frames * numChannels).
        let fed = samples.withUnsafeBufferPointer { buffer -> Int32 in
            chromaprint_feed(ctx, buffer.baseAddress, Int32(buffer.count))
        }
        if fed != 1 {
            throw FingerprinterError.feedFailed
        }

        guard chromaprint_finish(ctx) == 1 else {
            throw FingerprinterError.finishFailed
        }

        // Base64 fingerprint for AcoustID.
        var outC: UnsafeMutablePointer<CChar>?
        guard chromaprint_get_fingerprint(ctx, &outC) == 1, let outC else {
            throw FingerprinterError.getFingerprintFailed
        }
        let fingerprint = String(cString: outC)
        chromaprint_dealloc(outC)

        // Raw uint32 array — same values fpcalc -raw prints.
        var rawPtr: UnsafeMutablePointer<UInt32>?
        var rawSize: Int32 = 0
        var rawArray: [UInt32] = []
        if chromaprint_get_raw_fingerprint(ctx, &rawPtr, &rawSize) == 1, let rawPtr {
            rawArray = Array(UnsafeBufferPointer(start: rawPtr, count: Int(rawSize)))
            chromaprint_dealloc(rawPtr)
        }

        return Result(
            fingerprint: fingerprint,
            durationSeconds: durationSeconds,
            rawFingerprint: rawArray
        )
    }
}
