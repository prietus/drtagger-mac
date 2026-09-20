import Foundation
import Testing
@testable import DSTKit

@Suite("BitReader")
struct BitReaderTests {
    @Test func readsBitsMSBFirst() {
        let bytes: [UInt8] = [0b1011_0010, 0b0111_1111, 0xFF, 0x00, 0x80]
        bytes.withUnsafeBufferPointer { buf in
            var r = BitReader(buf)
            #expect(r.bit() == 1)
            #expect(r.bit() == 0)
            #expect(r.bits(3) == 0b110)
            #expect(r.bits(5) == 0b01001)          // crosses the byte boundary
            #expect(r.sbits(3) == -1)             // 111
            #expect(r.bits(11) == 0b111_1111_1111) // rest of byte 1 and all of byte 2
            #expect(r.bitsLeft == 40 - 24)
            #expect(r.bits(16) == 0x0080)
            #expect(r.bit() == 0)                 // past the end reads zeros
        }
    }

    @Test func riceGolomb() throws {
        // k = 2: "001" (2 zeros) then "10" → 2<<2 | 2 = 10, then sign bit 1 → -10.
        // Then "1" "00" → 0 (no sign bit read).
        let bytes: [UInt8] = [0b0011_0110, 0b0000_0000]
        try bytes.withUnsafeBufferPointer { buf in
            var r = BitReader(buf)
            let first = try r.signedRiceGolomb(k: 2)
            let second = try r.signedRiceGolomb(k: 2)
            #expect(first == -10)
            #expect(second == 0)
        }
    }
}

@Suite("DSTDecoder")
struct DSTDecoderTests {

    @Test func rejectsBadParameters() {
        #expect(throws: DSTDecoder.DSTError.badChannelCount(7)) { try DSTDecoder(channels: 7) }
        #expect(throws: DSTDecoder.DSTError.badSampleRate(48000)) { try DSTDecoder(channels: 2, sampleRate: 48000) }
        let d = try? DSTDecoder(channels: 2)
        #expect(d?.samplesPerFrame == 37632)
        #expect(d?.outputBytesPerFrame == 9408)
    }

    @Test func passesUncompressedFramesThrough() throws {
        let decoder = try DSTDecoder(channels: 2)
        var frame = Data([0x00])          // 0 (uncompressed), pad bit, 6 zero bits
        var payload = Data(count: 9408)
        for i in 0..<payload.count { payload[i] = UInt8(truncatingIfNeeded: i &* 31) }
        frame.append(payload)
        let out = try decoder.decode(frame)
        #expect(out == payload)

        // A short uncompressed frame is zero padded.
        let short = try decoder.decode(Data([0x00, 0xAB, 0xCD]))
        #expect(short.count == 9408)
        #expect(short[0] == 0xAB && short[1] == 0xCD && short[2] == 0)

        #expect(throws: DSTDecoder.DSTError.invalidData("bad uncompressed header")) {
            try decoder.decode(Data([0x3F, 0x00]))
        }
    }

    @Test func rejectsMultiSegmentFrames() throws {
        let decoder = try DSTDecoder(channels: 2)
        // 1 (compressed) 0 (not same segmentation) …
        #expect(throws: DSTDecoder.DSTError.unsupported("not same segmentation")) {
            try decoder.decode(Data([0b1000_0000, 0x00, 0x00]))
        }
    }
}

@Suite("DST throughput")
struct DSTThroughputTests {
    // Decodes 10 s of a real DST disc and reports frames per second. Skips
    // when the sample is missing.
    @Test func decodesTenSecondsQuickly() throws {
        let iso = URL(fileURLWithPath: NSString(string: "~/mactagger-samples/isos/David Bowie - Space Oddity.iso").expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: iso.path) else { return }
        // Read raw DST frames straight from the audio sectors (area TOC at 544, audio from 584).
        let handle = try FileHandle(forReadingFrom: iso)
        defer { try? handle.close() }
        try handle.seek(toOffset: 584 * 2048)
        let raw = try handle.read(upToCount: 4000 * 2048) ?? Data()
        var frames: [Data] = []
        var current: Data? = nil
        var offset = 0
        while offset + 2048 <= raw.count && frames.count < 750 {
            let sector = raw[offset..<(offset + 2048)]
            let header = sector[sector.startIndex]
            let packetCount = Int(header >> 5) & 7, frameCount = Int(header >> 2) & 7
            var p = 1
            var packets: [(Bool, Int, Int)] = []
            for _ in 0..<packetCount {
                let w = Int(sector[sector.startIndex + p]) << 8 | Int(sector[sector.startIndex + p + 1])
                p += 2
                packets.append(((w >> 15) & 1 == 1, (w >> 11) & 7, w & 0x7FF))
            }
            p += 4 * frameCount
            for (start, type, len) in packets {
                if type == 2 {
                    if start {
                        if let c = current { frames.append(c) }
                        current = Data()
                    }
                    current?.append(sector[(sector.startIndex + p)..<(sector.startIndex + p + len)])
                }
                p += len
            }
            offset += 2048
        }
        #expect(frames.count == 750)
        let decoder = try DSTDecoder(channels: 2)
        let started = Date()
        var bytes = 0
        for f in frames { bytes += try decoder.decode(f).count }
        let elapsed = Date().timeIntervalSince(started)
        print(String(format: "DST: %d frames (10 s of audio) decoded in %.2f s on one core → %.1fx realtime", frames.count, elapsed, 10 / elapsed))
        #expect(bytes == 750 * 9408)
    }
}
