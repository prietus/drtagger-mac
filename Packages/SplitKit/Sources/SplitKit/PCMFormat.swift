import Foundation

// Interleaved little-endian signed PCM, the exchange format between ffmpeg
// and the splitter. "Frame" here means one sample across all channels.
public struct PCMFormat: Sendable, Equatable, Codable, Hashable {

    public enum FormatError: LocalizedError, Equatable {
        case unsupportedBitDepth(Int)
        case invalid(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedBitDepth(let b): return "\(b)-bit PCM is not supported (16, 24 or 32 expected)."
            case .invalid(let m): return m
            }
        }
    }

    public let sampleRate: Int
    public let channels: Int
    public let bitsPerSample: Int

    public init(sampleRate: Int, channels: Int, bitsPerSample: Int) throws {
        guard sampleRate > 0 else { throw FormatError.invalid("Sample rate must be positive.") }
        guard channels > 0 && channels <= 8 else { throw FormatError.invalid("Unsupported channel count \(channels).") }
        guard [16, 24, 32].contains(bitsPerSample) else { throw FormatError.unsupportedBitDepth(bitsPerSample) }
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerSample = bitsPerSample
    }

    public static let cd = try! PCMFormat(sampleRate: 44100, channels: 2, bitsPerSample: 16)

    public var bytesPerSample: Int { bitsPerSample / 8 }
    public var bytesPerFrame: Int { bytesPerSample * channels }
    public var isCDAudio: Bool { self == PCMFormat.cd }

    // ffmpeg names: "-f s24le" and "-acodec pcm_s24le".
    public var ffmpegFormatName: String { "s\(bitsPerSample)le" }
    public var ffmpegCodecName: String { "pcm_s\(bitsPerSample)le" }

    public func byteOffset(ofSample sample: Int64) -> Int64 { sample * Int64(bytesPerFrame) }

    public var description: String {
        "\(bitsPerSample)-bit / \(Double(sampleRate) / 1000) kHz / \(channels) ch"
    }
}
