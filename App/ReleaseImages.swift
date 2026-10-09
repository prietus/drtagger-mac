import IdentifyKit
import Observation
import ProviderKit
import SwiftUI

// One photo of a release: from Cover Art Archive (typed: Front, Back, Obi…)
// or from the linked Discogs page (untyped: whatever users photographed).
struct GalleryImage: Identifiable, Hashable, Sendable {
    enum Kind: Int, Sendable, Comparable {
        case obi, front, back, medium, booklet, other, discogs
        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    let url: URL
    let thumbnail: URL?
    let kind: Kind
    let label: String

    var id: String { url.absoluteString }
}

// Loads and caches the photos of candidate releases on demand. Cover Art
// Archive needs no key; Discogs (where obi photos usually are) is used when
// a token is configured, through the MusicBrainz → Discogs link.
@Observable
@MainActor
final class ReleaseImagesService {

    enum State: Equatable {
        case loading
        case loaded([GalleryImage])
    }

    private(set) var states: [String: State] = [:]
    private let caa = CoverArtArchiveClient(userAgent: IdentifyService.userAgent)
    private let musicBrainz = MusicBrainzClient(userAgent: IdentifyService.userAgent)
    private var discogs: DiscogsClient?
    private var discogsToken = ""

    func images(for c: Candidate) -> [GalleryImage]? {
        if case .loaded(let list) = states[c.id] { return list }
        return nil
    }

    func isLoading(_ c: Candidate) -> Bool { states[c.id] == .loading }

    // The photo that best identifies a pressing: the obi, else the front.
    func preferred(for c: Candidate) -> GalleryImage? {
        images(for: c)?.min { $0.kind < $1.kind }
    }

    func load(_ c: Candidate, settings: AppSettings) async {
        guard states[c.id] == nil else { return }
        states[c.id] = .loading
        var list: [GalleryImage] = []

        if c.source == .musicbrainz, let caaImages = try? await caa.images(releaseID: c.providerID) {
            for i in caaImages {
                let types = i.types.map { $0.lowercased() }
                let kind: GalleryImage.Kind = types.contains("obi") ? .obi : i.isFront ? .front : i.isBack ? .back
                    : types.contains("medium") ? .medium : types.contains("booklet") ? .booklet : .other
                let label = i.types.isEmpty ? String(localized: "Image") : i.types.joined(separator: ", ")
                list.append(GalleryImage(url: i.large ?? i.fullURL, thumbnail: i.small ?? i.thumbnail, kind: kind, label: label))
            }
        }

        if settings.isDiscogsConfigured {
            let token = settings.discogsToken.trimmed
            if discogs == nil || token != discogsToken {
                discogs = DiscogsClient(userAgent: IdentifyService.userAgent, token: token)
                discogsToken = token
            }
            let ids: [String] = c.source == .discogs ? [c.providerID]
                : c.source == .musicbrainz ? ((try? await musicBrainz.discogsReleaseIDs(mbid: c.providerID)) ?? []) : []
            if let id = ids.first, let photos = try? await discogs?.images(releaseID: id) {
                for (n, p) in photos.enumerated() {
                    list.append(GalleryImage(url: p.url, thumbnail: p.thumbnail, kind: .discogs, label: "Discogs \(n + 1)"))
                }
            }
        }

        states[c.id] = .loaded(list.sorted { $0.kind < $1.kind })
    }
}

// A remote image fitted into a square, with a neutral placeholder.
struct RemoteThumbnail: View {
    let url: URL?
    let side: CGFloat

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image): image.resizable().aspectRatio(contentMode: .fit)
            case .empty where url != nil: ProgressView().controlSize(.small)
            default: Image(systemName: "photo").foregroundStyle(.tertiary)
            }
        }
        .frame(width: side, height: side)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// Every photo of one release, obi first; click one to see it large.
struct ReleaseGallerySheet: View {
    let scored: ScoredCandidate
    let isSelected: Bool
    let onChoose: () -> Void
    @Environment(ReleaseImagesService.self) private var images
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var viewing: ImageViewerItem?

    private var c: Candidate { scored.candidate }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(c.artist) – \(c.title)").font(.headline)
                    Text(ReleaseImagesService.edition(c)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(isSelected ? "Chosen" : "Choose This Release") { onChoose(); dismiss() }
                    .buttonStyle(.borderedProminent).disabled(isSelected)
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let list = images.images(for: c) {
                if list.isEmpty {
                    ContentUnavailableView("No photos for this release", systemImage: "photo",
                                           description: Text(settings.isDiscogsConfigured ? "Neither Cover Art Archive nor Discogs has images of it." : "Cover Art Archive has none; add a Discogs token in Settings to see Discogs photos, where obis usually are."))
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 14)], spacing: 14) {
                            ForEach(list) { img in
                                Button { viewing = ImageViewerItem(title: "\(c.title) · \(img.label)", url: img.url, data: nil, subtitle: img.url.host) } label: {
                                    VStack(spacing: 4) {
                                        RemoteThumbnail(url: img.thumbnail ?? img.url, side: 190)
                                        Text(img.kind == .obi ? "OBI" : img.label).font(.caption).bold(img.kind == .obi)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(2)
                    }
                }
            } else {
                ProgressView("Loading photos…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(18)
        .frame(minWidth: 680, minHeight: 520)
        .task { await images.load(c, settings: settings) }
        .sheet(item: $viewing) { item in ImageViewerSheet(item: item) }
    }
}

// The candidates side by side, each with its obi (or front): pick the one
// that matches the disc in your hands.
struct CompareCoversSheet: View {
    let candidates: [ScoredCandidate]
    let selectedID: String?
    let onChoose: (ScoredCandidate) -> Void
    @Environment(ReleaseImagesService.self) private var images
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var gallery: ScoredCandidate?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Compare covers").font(.headline)
                    Text("Click the pressing that matches your disc. Obis are shown when a photo of one exists.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 16)], spacing: 16) {
                    ForEach(candidates) { s in tile(s) }
                }
                .padding(2)
            }
        }
        .padding(18)
        .frame(minWidth: 760, minHeight: 600)
        .sheet(item: $gallery) { s in
            ReleaseGallerySheet(scored: s, isSelected: s.id == selectedID) { onChoose(s) }
        }
    }

    private func tile(_ s: ScoredCandidate) -> some View {
        let c = s.candidate
        let best = images.preferred(for: c)
        return VStack(alignment: .leading, spacing: 4) {
            Button { onChoose(s); dismiss() } label: {
                ZStack(alignment: .topLeading) {
                    RemoteThumbnail(url: best.map { $0.thumbnail ?? $0.url } ?? c.coverArtURL, side: 200)
                    if let best {
                        Text(best.kind == .obi ? "OBI" : best.label)
                            .font(.caption2).bold()
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(best.kind == .obi ? Color.orange : Color.black.opacity(0.55), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(6)
                    }
                    if s.id == selectedID {
                        Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.white, Color.accentColor)
                            .frame(width: 200, height: 200, alignment: .bottomTrailing).padding(-4)
                    }
                }
            }
            .buttonStyle(.plain)
            Text(c.title).font(.callout).bold().lineLimit(1)
            Text(ReleaseImagesService.edition(c)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            HStack {
                Text(String(format: "%.0f", s.score)).font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                Spacer()
                if let n = images.images(for: c)?.count, n > 0 {
                    Button("All \(n) photos") { gallery = s }.buttonStyle(.link).font(.caption)
                } else if images.isLoading(c) {
                    ProgressView().controlSize(.mini)
                }
            }
        }
        .frame(width: 200)
        .task { await images.load(c, settings: settings) }
    }
}

extension ReleaseImagesService {
    nonisolated static func edition(_ c: Candidate) -> String {
        [c.year, c.country, c.mediaFormat, c.label, c.catalogNumber, c.barcode].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
