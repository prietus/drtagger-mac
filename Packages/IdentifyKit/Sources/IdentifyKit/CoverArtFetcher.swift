import Foundation
import ImageIO
import LibraryKit
import ProviderKit

// Where a front cover can come from, best first: the release's own Cover
// Art Archive image, its release group, Discogs, iTunes, Deezer, and the
// scans already in the folder.
public struct ArtworkOption: Sendable, Equatable, Hashable, Identifiable, Codable {
    public enum Source: String, Sendable, Codable, Hashable {
        case coverArtArchive, coverArtArchiveGroup, discogs, itunes, deezer, local
    }

    public let source: Source
    public let url: URL                 // remote image or local file
    public let label: String            // "Cover Art Archive · 1400×1400"
    public let isLocal: Bool

    public var id: String { source.rawValue + ":" + url.absoluteString }
}

public struct FetchedArtwork: Sendable, Equatable {
    public let option: ArtworkOption
    public let data: Data
    public let width: Int
    public let height: Int
}

public actor CoverArtFetcher {

    public let userAgent: String
    private let session: URLSession
    private let caa: CoverArtArchiveClient
    private let itunes: ITunesSearchClient
    private let deezer: DeezerClient

    public init(userAgent: String) {
        self.userAgent = userAgent
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
        caa = CoverArtArchiveClient(userAgent: userAgent)
        itunes = ITunesSearchClient(userAgent: userAgent)
        deezer = DeezerClient(userAgent: userAgent)
    }

    // Every source that answers, in preference order. Nothing is downloaded
    // yet except what the listings themselves need.
    public func options(for candidate: Candidate, discogs: Candidate?, album: DetectedAlbum?, log: @Sendable (String) -> Void = { _ in }) async -> [ArtworkOption] {
        var out: [ArtworkOption] = []
        if candidate.source == .musicbrainz {
            if let images = try? await caa.images(releaseID: candidate.providerID), let front = images.first(where: \.isFront) ?? images.first {
                out.append(ArtworkOption(source: .coverArtArchive, url: front.fullURL, label: "Cover Art Archive (release)", isLocal: false))
            } else {
                log("Cover Art Archive: no image for this release.")
            }
            if let group = candidate.releaseGroupID, let url = URL(string: "https://coverartarchive.org/release-group/\(group)/front") {
                out.append(ArtworkOption(source: .coverArtArchiveGroup, url: url, label: "Cover Art Archive (release group)", isLocal: false))
            }
        }
        if let d = discogs ?? (candidate.source == .discogs ? candidate : nil), let url = d.coverArtURL {
            out.append(ArtworkOption(source: .discogs, url: url, label: "Discogs", isLocal: false))
        }
        if let albums = try? await itunes.searchAlbums(artist: candidate.artist, album: candidate.title, limit: 3), let hit = albums.first {
            out.append(ArtworkOption(source: .itunes, url: hit.artworkURL3000, label: "iTunes · \(hit.artist) – \(hit.title)", isLocal: false))
        }
        if let albums = try? await deezer.searchAlbums(artist: candidate.artist, album: candidate.title, limit: 3), let hit = albums.first, let url = hit.coverXL {
            out.append(ArtworkOption(source: .deezer, url: url, label: "Deezer · \(hit.artist) – \(hit.title)", isLocal: false))
        }
        for file in Self.localFronts(album) {
            out.append(ArtworkOption(source: .local, url: file, label: "Folder · \(file.lastPathComponent)", isLocal: true))
        }
        log("Artwork: \(out.count) source(s) available.")
        return out
    }

    // Downloads (or reads) one option; nil when it does not resolve to an image.
    public func fetch(_ option: ArtworkOption) async -> FetchedArtwork? {
        let data: Data
        if option.isLocal {
            guard let d = try? Data(contentsOf: option.url) else { return nil }
            data = d
        } else {
            var req = URLRequest(url: option.url)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            guard let (d, resp) = try? await session.data(for: req), let http = resp as? HTTPURLResponse, http.statusCode < 400, d.count > 1024 else { return nil }
            data = d
        }
        guard let dims = Self.dimensions(of: data), dims.width >= 200 else { return nil }
        return FetchedArtwork(option: option, data: data, width: dims.width, height: dims.height)
    }

    // First option that yields a usable image.
    public func best(for candidate: Candidate, discogs: Candidate?, album: DetectedAlbum?, log: @Sendable (String) -> Void = { _ in }) async -> FetchedArtwork? {
        for option in await options(for: candidate, discogs: discogs, album: album, log: log) {
            if let art = await fetch(option) {
                log("Artwork: using \(option.label), \(art.width)×\(art.height).")
                return art
            }
        }
        return nil
    }

    static func localFronts(_ album: DetectedAlbum?) -> [URL] {
        guard let album else { return [] }
        let files = album.artworkFiles
        func rank(_ u: URL) -> Int {
            let n = u.deletingPathExtension().lastPathComponent.lowercased()
            if n == "cover" || n == "front" || n == "folder" { return 0 }
            if n.contains("front") || n.contains("cover") || n.contains("frontal") { return 1 }
            if n.contains("back") || n.contains("obi") || n.contains("inlay") || n.contains("booklet") { return 9 }
            return 5
        }
        return files.sorted { rank($0) < rank($1) }.prefix(3).map { $0 }
    }

    static func dimensions(of data: Data) -> (width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }
}
