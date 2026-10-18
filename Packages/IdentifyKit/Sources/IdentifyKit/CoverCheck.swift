import CoreGraphics
import Foundation
import ImageIO
import ProviderKit
import Vision

// Does the cover the album already has look like the chosen release's?
// Vision feature prints measured on a real library: the same artwork
// downloaded twice ≈ 0, home scans of it 0.06–0.8, other covers of one
// series ≈ 0.8, unrelated covers 0.95 and up. Scans and series overlap, so
// only an unmistakable difference is reported.
public struct CoverCheck: Sendable {
    public static let differentThreshold: Float = 0.95

    let userAgent: String
    let discogsToken: String?

    public init(userAgent: String, discogsToken: String?) {
        self.userAgent = userAgent
        self.discogsToken = discogsToken
    }

    // The smallest distance between `local` and the release's front images;
    // nil when either side has no usable image.
    public func distance(local: Data, candidate: Candidate) async -> Float? {
        guard let mine = Self.featurePrint(local) else { return nil }
        var best: Float?
        for url in await frontImages(candidate) {
            guard let data = try? await download(url), let theirs = Self.featurePrint(data) else { continue }
            var d: Float = 0
            guard (try? mine.computeDistance(&d, to: theirs)) != nil else { continue }
            best = min(best ?? d, d)
            if d < 0.3 { break }
        }
        return best
    }

    func frontImages(_ c: Candidate) async -> [URL] {
        switch c.source {
        case .musicbrainz:
            let images = (try? await CoverArtArchiveClient(userAgent: userAgent).images(releaseID: c.providerID)) ?? []
            return images.filter(\.isFront).prefix(3).map { $0.small ?? $0.thumbnail ?? $0.fullURL }
        case .discogs:
            guard let discogs = ProviderClients.shared(userAgent: userAgent, acoustIDKey: nil, discogsToken: discogsToken).discogs,
                  let images = try? await discogs.images(releaseID: c.providerID) else { return [] }
            return images.filter(\.isPrimary).prefix(1).map { $0.thumbnail ?? $0.url }
        default:
            return []
        }
    }

    func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    public static func featurePrint(_ data: Data) -> VNFeaturePrintObservation? {
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 512,
                       kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = VNGenerateImageFeaturePrintRequestRevision2
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return request.results?.first
    }

    public static func distance(_ a: Data, _ b: Data) -> Float? {
        guard let pa = featurePrint(a), let pb = featurePrint(b) else { return nil }
        var d: Float = 0
        return (try? pa.computeDistance(&d, to: pb)) != nil ? d : nil
    }
}
