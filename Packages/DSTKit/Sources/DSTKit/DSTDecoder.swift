import Foundation

// Direct Stream Transfer decoder producing DSD bits.
//
// Swift port of FFmpeg's libavcodec/dstdec.c (LGPL 2.1+, Copyright (c)
// 2014 Peter Ross), stopped before its DSD-to-PCM stage so the lossless
// bitstream can be written to DSF. One DST frame holds 1/75 s of audio:
// 588 * 64 = 37632 samples per channel at DSD64. Output bytes are
// interleaved per channel with the earliest sample in the MSB, the same
// layout uncompressed SACD frames use.
//
// Supported: the "same segmentation, single segment" layout every SACD in
// the wild uses. Multi-segment frames are reported as unsupported.
public final class DSTDecoder {

    public enum DSTError: LocalizedError, Equatable {
        case badChannelCount(Int)
        case badSampleRate(Int)
        case emptyFrame
        case invalidData(String)
        case unsupported(String)

        public var errorDescription: String? {
            switch self {
            case .badChannelCount(let n): return "DST supports up to 6 channels, not \(n)."
            case .badSampleRate(let r): return "Unsupported DSD sample rate \(r)."
            case .emptyFrame: return "Empty DST frame."
            case .invalidData(let m): return "Invalid DST data: \(m)."
            case .unsupported(let m): return "Unsupported DST feature: \(m)."
            }
        }
    }

    public static let maxChannels = 6
    static let maxElements = 12
    static let maxCoefficients = 128

    public let channels: Int
    public let sampleRate: Int
    public let samplesPerFrame: Int
    public var outputBytesPerFrame: Int { samplesPerFrame / 8 * channels }

    // Filter coefficient sets and probability tables.
    private struct Table {
        var elements = 1
        var length = [Int](repeating: 0, count: DSTDecoder.maxElements)
        var coeff = [Int32](repeating: 0, count: DSTDecoder.maxElements * DSTDecoder.maxCoefficients)
    }

    private var fsets = Table()
    private var probs = Table()
    private var mapF = [Int](repeating: 0, count: DSTDecoder.maxChannels)
    private var mapP = [Int](repeating: 0, count: DSTDecoder.maxChannels)
    private var halfProb = [Bool](repeating: false, count: DSTDecoder.maxChannels)

    // filter[(elem * 16 + byteIndex) * 256 + byteValue]
    private let filter: UnsafeMutablePointer<Int16>
    private let output: UnsafeMutablePointer<UInt8>
    // 128-bit sample history per channel: lo words then hi words.
    private let status: UnsafeMutablePointer<UInt64>

    private static let fsetsPred: [[Int32]] = [[-8, 0, 0], [-16, 8, 0], [-9, -5, 6]]
    private static let probsPred: [[Int32]] = [[-8, 0, 0], [-16, 8, 0], [-24, 24, -8]]

    static let bitReverse: [UInt8] = (0..<256).map { v -> UInt8 in
        var b = UInt8(v), r: UInt8 = 0
        for _ in 0..<8 { r = (r << 1) | (b & 1); b >>= 1 }
        return r
    }

    public init(channels: Int, sampleRate: Int = 2_822_400) throws {
        guard (1...DSTDecoder.maxChannels).contains(channels) else { throw DSTError.badChannelCount(channels) }
        // sampleRate is the DSD bit rate (2822400 for DSD64); a frame is
        // 588 CD samples long at the equivalent oversampling ratio.
        let fs44 = sampleRate / 44100
        let spf = 588 * fs44
        guard sampleRate % 44100 == 0, fs44 >= 8, fs44 % 8 == 0, fs44 <= 512 * 8 else {
            throw DSTError.badSampleRate(sampleRate)
        }
        self.channels = channels
        self.sampleRate = sampleRate
        self.samplesPerFrame = spf
        filter = UnsafeMutablePointer<Int16>.allocate(capacity: DSTDecoder.maxElements * 16 * 256)
        filter.initialize(repeating: 0, count: DSTDecoder.maxElements * 16 * 256)
        output = UnsafeMutablePointer<UInt8>.allocate(capacity: spf / 8 * channels)
        output.initialize(repeating: 0, count: spf / 8 * channels)
        status = UnsafeMutablePointer<UInt64>.allocate(capacity: 2 * DSTDecoder.maxChannels)
        status.initialize(repeating: 0, count: 2 * DSTDecoder.maxChannels)
    }

    deinit {
        filter.deallocate()
        output.deallocate()
        status.deallocate()
    }

    // Decodes one frame into interleaved MSB-first DSD bytes. Optimised
    // even in debug builds: the per-sample loop is far too slow at -Onone.
    @_optimize(speed)
    public func decode(_ frame: Data) throws -> Data {
        guard frame.count > 1 else { throw DSTError.emptyFrame }
        let outBytes = outputBytesPerFrame
        return try frame.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data in
            let bytes = raw.bindMemory(to: UInt8.self)
            var gb = BitReader(bytes)

            // Uncompressed frame: 0, x, 000000, then raw DSD bytes.
            if gb.bit() == 0 {
                _ = gb.bit()
                guard gb.bits(6) == 0 else { throw DSTError.invalidData("bad uncompressed header") }
                var out = Data(count: outBytes)
                let n = min(bytes.count - 1, outBytes)
                out.replaceSubrange(0..<n, with: UnsafeRawBufferPointer(rebasing: raw[1..<(1 + n)]))
                return out
            }

            // Segmentation (10.4 - 10.6): only one segment for all channels.
            guard gb.bit() == 1 else { throw DSTError.unsupported("not same segmentation") }
            guard gb.bit() == 1 else { throw DSTError.unsupported("not same segmentation for all channels") }
            guard gb.bit() == 1 else { throw DSTError.unsupported("not end of channel segmentation") }

            // Mapping (10.7 - 10.9).
            let sameMap = gb.bit() == 1
            try readMap(&gb, table: &fsets, map: &mapF)
            if sameMap {
                probs.elements = fsets.elements
                mapP = mapF
            } else {
                try readMap(&gb, table: &probs, map: &mapP)
            }

            // Half probability (10.10).
            for ch in 0..<channels { halfProb[ch] = gb.bit() == 1 }

            // Filter coefficient sets (10.12) and probability tables (10.13).
            try readTable(&gb, table: &fsets, pred: DSTDecoder.fsetsPred, lengthBits: 7, coeffBits: 9, isSigned: true, offset: 0)
            try readTable(&gb, table: &probs, pred: DSTDecoder.probsPred, lengthBits: 6, coeffBits: 7, isSigned: false, offset: 1)

            // Arithmetic coded data (10.11).
            guard gb.bit() == 0 else { throw DSTError.invalidData("reserved bit set") }
            var ac = ArithCoder(a: 4095, c: UInt32(gb.bits(12)))
            try buildFilter()

            let out = output
            out.initialize(repeating: 0, count: outBytes)

            let firstCoeff = Int(fsets.coeff[0])
            _ = ac.get(Int(DSTDecoder.bitReverse[firstCoeff & 127] >> 1) + 1, &gb)

            // Everything the sample loop needs as plain pointers, so the
            // optimised loop never touches Array or class storage.
            try mapF.withUnsafeBufferPointer { mapFPtr in
                try mapP.withUnsafeBufferPointer { mapPPtr in
                    try halfProb.withUnsafeBufferPointer { halfPtr in
                        try fsets.length.withUnsafeBufferPointer { fLenPtr in
                            try probs.length.withUnsafeBufferPointer { pLenPtr in
                                try probs.coeff.withUnsafeBufferPointer { pCoeffPtr in
                                    status.initialize(repeating: 0xAAAA_AAAA_AAAA_AAAA, count: 2 * DSTDecoder.maxChannels)
                                    try DSTDecoder.decodeSamples(
                                        samplesPerFrame: samplesPerFrame, channels: channels,
                                        filter: filter, out: out, status: status,
                                        mapF: mapFPtr.baseAddress!, mapP: mapPPtr.baseAddress!, halfProb: halfPtr.baseAddress!,
                                        fsetsLength: fLenPtr.baseAddress!, probsLength: pLenPtr.baseAddress!, probsCoeff: pCoeffPtr.baseAddress!,
                                        bytes: bytes.baseAddress!, byteCount: bytes.count, bitPosition: &gb.position, acA: &ac.a, acC: &ac.c
                                    )
                                }
                            }
                        }
                    }
                }
            }
            return Data(bytes: out, count: outBytes)
        }
    }

    // The per-sample loop (10.11 + filter prediction). Compiled optimised
    // even in debug builds and written against raw pointers only.
    @_optimize(speed)
    private static func decodeSamples(
        samplesPerFrame: Int, channels: Int,
        filter: UnsafeMutablePointer<Int16>, out: UnsafeMutablePointer<UInt8>, status: UnsafeMutablePointer<UInt64>,
        mapF: UnsafePointer<Int>, mapP: UnsafePointer<Int>, halfProb: UnsafePointer<Bool>,
        fsetsLength: UnsafePointer<Int>, probsLength: UnsafePointer<Int>, probsCoeff: UnsafePointer<Int32>,
        bytes: UnsafePointer<UInt8>, byteCount: Int, bitPosition: inout Int, acA: inout UInt32, acC: inout UInt32
    ) throws {
        let loPtr = status
        let hiPtr = status + DSTDecoder.maxChannels
        var pos = bitPosition
        var a = acA
        var c = acC
        defer { bitPosition = pos; acA = a; acC = c }
        do {
            do {
                let stride = DSTDecoder.maxCoefficients
                var i = 0
                while i < samplesPerFrame {
                    let outIndex = (i >> 3) * channels
                    let outShift = UInt8(7 - (i & 7))
                    var ch = 0
                    while ch < channels {
                        let felem = mapF[ch]
                        let base = filter + felem * 16 * 256
                        let lo = loPtr[ch], hi = hiPtr[ch]
                        var sum: Int32 = 0
                        sum &+= Int32(base[0 * 256 + Int(lo & 0xFF)])
                        sum &+= Int32(base[1 * 256 + Int((lo >> 8) & 0xFF)])
                        sum &+= Int32(base[2 * 256 + Int((lo >> 16) & 0xFF)])
                        sum &+= Int32(base[3 * 256 + Int((lo >> 24) & 0xFF)])
                        sum &+= Int32(base[4 * 256 + Int((lo >> 32) & 0xFF)])
                        sum &+= Int32(base[5 * 256 + Int((lo >> 40) & 0xFF)])
                        sum &+= Int32(base[6 * 256 + Int((lo >> 48) & 0xFF)])
                        sum &+= Int32(base[7 * 256 + Int((lo >> 56) & 0xFF)])
                        sum &+= Int32(base[8 * 256 + Int(hi & 0xFF)])
                        sum &+= Int32(base[9 * 256 + Int((hi >> 8) & 0xFF)])
                        sum &+= Int32(base[10 * 256 + Int((hi >> 16) & 0xFF)])
                        sum &+= Int32(base[11 * 256 + Int((hi >> 24) & 0xFF)])
                        sum &+= Int32(base[12 * 256 + Int((hi >> 32) & 0xFF)])
                        sum &+= Int32(base[13 * 256 + Int((hi >> 40) & 0xFF)])
                        sum &+= Int32(base[14 * 256 + Int((hi >> 48) & 0xFF)])
                        sum &+= Int32(base[15 * 256 + Int((hi >> 56) & 0xFF)])
                        let predict = Int16(truncatingIfNeeded: sum)

                        let prob: Int
                        if !halfProb[ch] || i >= fsetsLength[felem] {
                            let pelem = mapP[ch]
                            let index = Int(predict.magnitude) >> 3
                            prob = Int(probsCoeff[pelem * stride + min(index, probsLength[pelem] - 1)])
                        } else {
                            prob = 128
                        }

                        // Arithmetic decoder step (10.11), inlined.
                        let k = (a >> 8) | ((a >> 7) & 1)
                        let q = k &* UInt32(truncatingIfNeeded: prob)
                        let aq = a &- q
                        let residual: Int
                        if c < aq {
                            a = aq
                            residual = 1
                        } else {
                            a = q
                            c = c &- aq
                            residual = 0
                        }
                        if a < 2048 {
                            let n = 11 - (31 - a.leadingZeroBitCount)
                            let byte = pos >> 3
                            let off = pos & 7
                            var window: UInt64 = 0
                            var kk = 0
                            while kk < 3 {
                                let idx = byte + kk
                                window = (window << 8) | UInt64(idx < byteCount ? bytes[idx] : 0)
                                kk += 1
                            }
                            let bitsRead = (window >> UInt64(24 - off - n)) & ((1 << UInt64(n)) - 1)
                            pos += n
                            a <<= UInt32(n)
                            c = (c << UInt32(n)) | UInt32(truncatingIfNeeded: bitsRead)
                        }
                        let v = (Int(predict >> 15) ^ residual) & 1
                        out[outIndex + ch] |= UInt8(v) << outShift

                        hiPtr[ch] = (hi << 1) | (lo >> 63)
                        loPtr[ch] = (lo << 1) | UInt64(v)
                        ch += 1
                    }
                    i += 1
                }
            }
        }
    }

    // MARK: - Tables

    private func readMap(_ gb: inout BitReader, table: inout Table, map: inout [Int]) throws {
        table.elements = 1
        map[0] = 0
        if gb.bit() == 0 {
            for ch in 1..<channels {
                let bits = log2Floor(table.elements) + 1
                map[ch] = gb.bits(bits)
                if map[ch] == table.elements {
                    table.elements += 1
                    if table.elements >= DSTDecoder.maxElements { throw DSTError.invalidData("too many map elements") }
                } else if map[ch] > table.elements {
                    throw DSTError.invalidData("map element out of range")
                }
            }
        } else {
            for ch in 0..<DSTDecoder.maxChannels { map[ch] = 0 }
        }
    }

    private func readTable(_ gb: inout BitReader, table: inout Table, pred: [[Int32]], lengthBits: Int, coeffBits: Int, isSigned: Bool, offset: Int) throws {
        let stride = DSTDecoder.maxCoefficients
        for i in 0..<table.elements {
            table.length[i] = gb.bits(lengthBits) + 1
            guard table.length[i] <= stride else { throw DSTError.invalidData("table too long") }
            let row = i * stride
            if gb.bit() == 0 {
                for j in 0..<table.length[i] {
                    table.coeff[row + j] = Int32((isSigned ? gb.sbits(coeffBits) : gb.bits(coeffBits)) + offset)
                }
            } else {
                let method = gb.bits(2)
                guard method != 3 else { throw DSTError.invalidData("bad coding method") }
                for j in 0..<(method + 1) {
                    table.coeff[row + j] = Int32((isSigned ? gb.sbits(coeffBits) : gb.bits(coeffBits)) + offset)
                }
                let lsbSize = gb.bits(3)
                if method + 1 < table.length[i] {
                    for j in (method + 1)..<table.length[i] {
                        var x: Int32 = 0
                        for k in 0...method {
                            x = x &+ pred[method][k] &* table.coeff[row + j - k - 1]
                        }
                        var c = try gb.signedRiceGolomb(k: lsbSize)
                        if x >= 0 {
                            c -= Int((x + 4) / 8)
                        } else {
                            c += Int((-x + 3) / 8)
                        }
                        if !isSigned {
                            guard c >= offset && c < offset + (1 << coeffBits) else {
                                throw DSTError.invalidData("probability out of range")
                            }
                        }
                        table.coeff[row + j] = Int32(c)
                    }
                }
            }
        }
    }

    private func buildFilter() throws {
        let stride = DSTDecoder.maxCoefficients
        for i in 0..<fsets.elements {
            let length = fsets.length[i]
            for j in 0..<16 {
                let total = max(0, min(8, length - j * 8))
                for k in 0..<256 {
                    var v: Int64 = 0
                    for l in 0..<total {
                        let sign: Int64 = ((k >> l) & 1) == 1 ? 1 : -1
                        v += sign * Int64(fsets.coeff[i * stride + j * 8 + l])
                    }
                    guard let v16 = Int16(exactly: v) else { throw DSTError.invalidData("filter overflow") }
                    filter[(i * 16 + j) * 256 + k] = v16
                }
            }
        }
    }
}

@inline(__always)
private func log2Floor(_ v: Int) -> Int {
    v <= 0 ? 0 : (Int.bitWidth - 1 - v.leadingZeroBitCount)
}

// MARK: - Arithmetic decoder (10.11)

private struct ArithCoder {
    var a: UInt32
    var c: UInt32

    @inline(__always) @_optimize(speed)
    mutating func get(_ p: Int, _ gb: inout BitReader) -> Int {
        let k = (a >> 8) | ((a >> 7) & 1)
        let q = k &* UInt32(p)
        let aq = a &- q
        let e = c < aq
        if e {
            a = aq
        } else {
            a = q
            c = c &- aq
        }
        if a < 2048 {
            let n = 11 - (31 - a.leadingZeroBitCount)
            a <<= UInt32(n)
            c = (c << UInt32(n)) | UInt32(gb.bits(n))
        }
        return e ? 1 : 0
    }
}

// MARK: - Bit reader (MSB first)

struct BitReader {
    let bytes: UnsafeBufferPointer<UInt8>
    var position = 0                       // in bits

    init(_ bytes: UnsafeBufferPointer<UInt8>) {
        self.bytes = bytes
    }

    var bitsLeft: Int { bytes.count * 8 - position }

    @inline(__always) @_optimize(speed)
    mutating func bit() -> Int {
        let byte = position >> 3
        let v = byte < bytes.count ? Int((bytes[byte] >> UInt8(7 - (position & 7))) & 1) : 0
        position += 1
        return v
    }

    // Up to 32 bits.
    @inline(__always) @_optimize(speed)
    mutating func bits(_ n: Int) -> Int {
        guard n > 0 else { return 0 }
        let byte = position >> 3
        let offset = position & 7
        var window: UInt64 = 0
        for k in 0..<5 {
            let i = byte + k
            window = (window << 8) | UInt64(i < bytes.count ? bytes[i] : 0)
        }
        let v = (window >> UInt64(40 - offset - n)) & ((1 << UInt64(n)) - 1)
        position += n
        return Int(v)
    }

    @inline(__always)
    mutating func sbits(_ n: Int) -> Int {
        let v = bits(n)
        return v >= (1 << (n - 1)) ? v - (1 << n) : v
    }

    // Unary count of zero bits followed by k literal bits (JPEG-LS style
    // Rice-Golomb, no escape), then an optional sign bit when non-zero.
    mutating func signedRiceGolomb(k: Int) throws -> Int {
        var zeros = 0
        while bit() == 0 {
            zeros += 1
            if bitsLeft <= 0 { throw DSTDecoder.DSTError.invalidData("golomb code runs past the frame") }
        }
        var v = bits(k) + (zeros << k)
        if v != 0 && bit() == 1 { v = -v }
        return v
    }
}
