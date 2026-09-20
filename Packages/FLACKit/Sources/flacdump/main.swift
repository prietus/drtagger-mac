import Foundation
import FLACKit

guard CommandLine.arguments.count == 2 else {
    print("usage: flacdump <file.flac>")
    exit(2)
}
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let file = try FLACFile(url: url)
let si = file.streamInfo
print("== STREAMINFO ==")
print("  rate=\(si.sampleRate) ch=\(si.channels) bits=\(si.bitsPerSample)")
print("  samples=\(si.totalSamples) duration=\(String(format: "%.2f", si.durationSeconds))s")
print("  md5=\(si.md5Signature.map { String(format: "%02x", $0) }.joined())")
print("  audioOffset=\(file.audioFrameOffset) audioLength=\(file.audioFrameLength)")
print("== BLOCKS ==")
for b in file.blocks {
    let kind: String
    switch b.payload {
    case .inline: kind = "inline"
    case .reference: kind = "ref"
    }
    print("  \(b.type) \(b.payload.length)B \(kind)\(b.isLast ? " LAST" : "")")
}
if let vc = file.vorbisComment {
    print("== VORBIS_COMMENT ==")
    print("  vendor: \(vc.vendor)")
    for (n, v) in vc.fields {
        let short = v.count > 100 ? String(v.prefix(100)) + "…" : v
        print("  \(n)=\(short)")
    }
}
