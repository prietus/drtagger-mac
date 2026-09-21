import CoreGraphics
import Foundation
import ImageIO
import Vision

// Vision-based recogniser for album artwork: EAN/UPC barcodes plus OCR'd
// catalog numbers (OBI strips, back covers). Ported from drtagger /
// OBIScanner to CGImage so it runs on macOS without UIKit.
public struct ArtworkScanResult: Sendable, Equatable, Codable, Hashable {
    public let url: URL
    public let barcodes: [String]          // EAN-13 / EAN-8 / UPC-E payloads
    public let catalogNumbers: [String]    // "PREFIX-NUMBER"
    public let recognizedTexts: [String]
    public let confidence: Float

    public var hasHit: Bool { !barcodes.isEmpty || !catalogNumbers.isEmpty }
}

public struct ArtworkScanner: Sendable {

    public init() {}

    // Loads the image downscaled to at most `maxPixel` on its longest side;
    // Vision's accurate recogniser is slow on 5000 px booklet scans and
    // barcodes are found reliably at 2000 px.
    public func scan(_ url: URL, maxPixel: Int = 1800) async throws -> ArtworkScanResult {
        guard let image = Self.loadImage(url, maxPixel: maxPixel) else {
            return ArtworkScanResult(url: url, barcodes: [], catalogNumbers: [], recognizedTexts: [], confidence: 0)
        }
        // Barcodes: try the three orientations, they are cheap.
        var barcodes = Set<String>()
        for oriented in [image, Self.rotated(image, clockwise: true), Self.rotated(image, clockwise: false)].compactMap({ $0 }) {
            for code in (try? await Self.detectBarcodes(oriented)) ?? [] {
                barcodes.insert(code)
            }
        }
        var (texts, confidence) = try await Self.recognizeText(image)
        var catalogs = CatalogNumberParser.extract(from: texts).map(\.formatted)
        // OBI strips are usually photographed rotated; only rescan when the
        // first pass found no catalog number.
        let elongated = Double(max(image.width, image.height)) / Double(max(1, min(image.width, image.height))) >= 1.6
        if catalogs.isEmpty && elongated {
            for rotated in [Self.rotated(image, clockwise: false), Self.rotated(image, clockwise: true)].compactMap({ $0 }) {
                if let (rTexts, rConf) = try? await Self.recognizeText(rotated) {
                    let rCats = CatalogNumberParser.extract(from: rTexts).map(\.formatted)
                    if !rCats.isEmpty {
                        texts = rTexts
                        confidence = rConf
                        catalogs = rCats
                        break
                    }
                }
            }
        }
        return ArtworkScanResult(
            url: url,
            barcodes: Array(barcodes).sorted(),
            catalogNumbers: catalogs,
            recognizedTexts: texts,
            confidence: confidence
        )
    }

    // MARK: Vision

    static func detectBarcodes(_ image: CGImage) async throws -> [String] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], any Error>) in
            let gate = ResumeGate(continuation)
            let request = VNDetectBarcodesRequest { request, error in
                if let error { gate.resume(throwing: error); return }
                let codes = (request.results as? [VNBarcodeObservation] ?? []).compactMap(\.payloadStringValue)
                gate.resume(returning: codes)
            }
            request.symbologies = [.ean13, .ean8, .upce]
            do {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            } catch {
                gate.resume(throwing: error)
            }
        }
    }

    static func recognizeText(_ image: CGImage) async throws -> ([String], Float) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<([String], Float), any Error>) in
            let gate = ResumeGate(continuation)
            let request = VNRecognizeTextRequest { request, error in
                if let error { gate.resume(throwing: error); return }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                var texts: [String] = []
                var total: Float = 0
                for o in observations {
                    if let c = o.topCandidates(1).first {
                        texts.append(c.string)
                        total += c.confidence
                    }
                }
                gate.resume(returning: (texts, observations.isEmpty ? 0 : total / Float(observations.count)))
            }
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en", "ja", "de", "fr", "es", "it", "pt"]
            request.usesLanguageCorrection = false
            do {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            } catch {
                gate.resume(throwing: error)
            }
        }
    }

    // MARK: Images

    static func loadImage(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func rotated(_ image: CGImage, clockwise: Bool) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: h, height: w, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: CGFloat(h) / 2, y: CGFloat(w) / 2)
        ctx.rotate(by: clockwise ? -.pi / 2 : .pi / 2)
        ctx.translateBy(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    // Vision can report the same failure through the request callback and
    // by throwing from perform(); only the first resume may win.
    private final class ResumeGate<T: Sendable>: @unchecked Sendable {
        private var done = false
        private let lock = NSLock()
        let continuation: CheckedContinuation<T, any Error>
        init(_ c: CheckedContinuation<T, any Error>) { continuation = c }
        func resume(returning v: T) { lock.lock(); defer { lock.unlock() }; guard !done else { return }; done = true; continuation.resume(returning: v) }
        func resume(throwing e: any Error) { lock.lock(); defer { lock.unlock() }; guard !done else { return }; done = true; continuation.resume(throwing: e) }
    }
}

// MARK: - Catalog numbers

public struct CatalogNumber: Hashable, Sendable, Codable {
    public let prefix: String
    public let number: String
    public var formatted: String { "\(prefix)-\(number)" }
}

public enum CatalogNumberParser {
    // Japanese style: UICY-1234, SICP-30785, TOCJ-15001.
    // Western style: PRESTIGE-7142, VDJ-1541, CDV 2222.
    private static let hyphenated = try! NSRegularExpression(pattern: #"\b([A-Z]{2,10})-(\d{1,6})\b"#)
    private static let spaced = try! NSRegularExpression(pattern: #"\b([A-Z]{2,10})\s+(\d{3,6})\b"#)
    private static let looseHyphen = try! NSRegularExpression(pattern: #"\b([A-Z]{2,10})\s*[-~_]\s*(\d{1,6})\b"#)
    // Glued: PD83889, UICY40164 (labels often print no separator).
    private static let glued = try! NSRegularExpression(pattern: #"\b([A-Z]{2,6})(\d{4,7})\b"#)
    // Common OCR'd words that look like a prefix but never are.
    private static let stopWords: Set<String> = [
        "CD", "DVD", "SACD", "LP", "TRACK", "DISC", "SIDE", "TOTAL", "TIME", "PAGE", "VOL", "NO", "STEREO", "MONO",
        "ISBN", "EAN", "UPC", "JAN", "TEL", "FAX", "BOX", "SUITE", "NEW", "YORK", "LONDON", "TOKYO", "PARIS",
        "JANUARY", "FEBRUARY", "MARCH", "APRIL", "MAY", "JUNE", "JULY", "AUGUST", "SEPTEMBER", "OCTOBER", "NOVEMBER", "DECEMBER",
        "ENERO", "FEBRERO", "MARZO", "ABRIL", "MAYO", "JUNIO", "JULIO", "AGOSTO", "SEPTIEMBRE", "OCTUBRE", "NOVIEMBRE", "DICIEMBRE",
    ]

    public static func extract(from lines: [String]) -> [CatalogNumber] {
        var results: [CatalogNumber] = []
        var seen = Set<String>()
        for line in lines {
            let cleaned = line.uppercased()
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            for pattern in [hyphenated, spaced, looseHyphen, glued] {
                for match in pattern.matches(in: cleaned, range: range) {
                    guard match.numberOfRanges == 3,
                          let p = Range(match.range(at: 1), in: cleaned),
                          let n = Range(match.range(at: 2), in: cleaned) else { continue }
                    let prefix = String(cleaned[p]), number = String(cleaned[n])
                    guard !stopWords.contains(prefix) else { continue }
                    let cat = CatalogNumber(prefix: prefix, number: number)
                    if seen.insert(cat.formatted).inserted { results.append(cat) }
                }
            }
        }
        return results
    }

    // "sicp 1700" == "SICP-1700" == "SICP1700".
    public static func normalize(_ s: String) -> String {
        s.uppercased().filter { $0.isLetter || $0.isNumber }
    }
}
