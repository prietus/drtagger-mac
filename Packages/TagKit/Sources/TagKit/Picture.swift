import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// An embedded picture as every container understands it (ID3 APIC types).
public struct Picture: Sendable, Equatable, Hashable, Codable {
    public enum Kind: Int, Sendable, Codable, Hashable {
        case other = 0, icon = 1, otherIcon = 2, front = 3, back = 4, leaflet = 5, media = 6
        case leadArtist = 7, artist = 8, conductor = 9, band = 10, composer = 11, lyricist = 12
        case recordingLocation = 13, duringRecording = 14, duringPerformance = 15, screenCapture = 16
        case brightFish = 17, illustration = 18, bandLogo = 19, publisherLogo = 20
    }

    public let kind: Kind
    public let mimeType: String
    public let data: Data
    public let width: Int
    public let height: Int
    public let description: String

    public init(kind: Kind, mimeType: String, data: Data, width: Int, height: Int, description: String = "") {
        self.kind = kind
        self.mimeType = mimeType
        self.data = data
        self.width = width
        self.height = height
        self.description = description
    }

    public var isFront: Bool { kind == .front }
    public var fileExtension: String { mimeType == "image/png" ? "png" : "jpg" }
}

// Summary kept in backups and shown in the preview (no pixel data).
public struct PictureInfo: Sendable, Equatable, Hashable, Codable {
    public let kind: Picture.Kind
    public let mimeType: String
    public let width: Int
    public let height: Int
    public let byteCount: Int

    public init(_ p: Picture) {
        kind = p.kind; mimeType = p.mimeType; width = p.width; height = p.height; byteCount = p.data.count
    }
}

public enum ArtworkError: Error, LocalizedError, Equatable {
    case undecodable
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .undecodable: return "The image could not be decoded."
        case .encodingFailed: return "The image could not be encoded."
        }
    }
}

// Turns any downloaded or scanned image into the front cover to embed:
// longest side capped, re-encoded as JPEG. Small PNGs stay PNG so line art
// and logos do not pick up artefacts.
public enum ArtworkProcessor {

    public static func dimensions(of data: Data) -> (width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    public static func mimeType(of data: Data) -> String? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(src) as String?,
              let ut = UTType(type), let mime = ut.preferredMIMEType else { return nil }
        return mime
    }

    public static func prepared(from data: Data, kind: Picture.Kind = .front, maxPixels: Int, jpegQuality: Double = 0.9, keepPNGUpTo: Int = 600) throws -> Picture {
        guard let (w, h) = dimensions(of: data), let mime = mimeType(of: data) else { throw ArtworkError.undecodable }
        let longest = max(w, h)
        let isPNG = mime == "image/png"
        if longest <= maxPixels, (mime == "image/jpeg" || (isPNG && longest <= keepPNGUpTo)) {
            return Picture(kind: kind, mimeType: mime, data: data, width: w, height: h)
        }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { throw ArtworkError.undecodable }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: min(longest, maxPixels),
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { throw ArtworkError.undecodable }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { throw ArtworkError.encodingFailed }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ArtworkError.encodingFailed }
        return Picture(kind: kind, mimeType: "image/jpeg", data: out as Data, width: image.width, height: image.height)
    }
}
