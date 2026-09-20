import ImageIO
import LibraryKit
import SwiftUI

// Right column: what the scanner found for one album. Identification,
// candidates and the tag diff arrive in later phases and slot in below
// the header.
struct AlbumInspectorView: View {
    let record: AlbumRecord

    private var detected: DetectedAlbum? { record.detected }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let detected {
                    overview(detected)
                    if record.isSplittable {
                        DiscIdentityView(record: record)
                    }
                    if let sacd = detected.sacd {
                        sacdSection(sacd)
                        SACDExtractView(record: record, sacd: sacd)
                    }
                    ForEach(detected.discs, id: \.number) { disc in
                        discSection(disc, showNumber: detected.discs.count > 1)
                    }
                    if !detected.artworkFiles.isEmpty {
                        artworkSection(detected.artworkFiles)
                    }
                } else {
                    Text("No scan details stored for this album. Use Rescan.")
                        .foregroundStyle(.secondary)
                }
                if !record.issues.isEmpty {
                    issuesSection(record.issues)
                }
                if let error = record.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            if let cover = detected?.artworkFiles.first {
                ArtworkThumbnail(url: cover, side: 96)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
                    .frame(width: 96, height: 96)
                    .overlay(Image(systemName: "opticaldisc").font(.largeTitle).foregroundStyle(.secondary))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(record.displayTitle)
                    .font(.title2)
                    .bold()
                    .textSelection(.enabled)
                if let artist = record.artistHint, !artist.isEmpty {
                    Text(artist)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                HStack(spacing: 6) {
                    Label(record.state.label, systemImage: record.state.systemImage)
                    if let year = record.yearHint {
                        Text("·")
                        Text(year)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                Text(record.url.path)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }

    private func overview(_ album: DetectedAlbum) -> some View {
        GroupBox("Source") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Kind").foregroundStyle(.secondary)
                    Text(album.kind.displayName)
                }
                GridRow {
                    Text("Tracks").foregroundStyle(.secondary)
                    Text("\(album.trackCount)")
                }
                if album.kind != .sacdISO {
                    GridRow {
                        Text("Discs").foregroundStyle(.secondary)
                        Text("\(album.discs.count)")
                    }
                    GridRow {
                        Text("Formats").foregroundStyle(.secondary)
                        Text(album.formats.map(\.displayName).sorted().joined(separator: ", "))
                    }
                }
                if let iso = album.isoFile {
                    GridRow {
                        Text("Image size").foregroundStyle(.secondary)
                        Text(ByteCountFormatter.string(fromByteCount: iso.fileSize, countStyle: .file))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private func sacdSection(_ sacd: SACDInfo) -> some View {
        GroupBox("SACD") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                if let title = sacd.title {
                    GridRow { Text("Disc title").foregroundStyle(.secondary); Text(title) }
                }
                if let artist = sacd.artist {
                    GridRow { Text("Disc artist").foregroundStyle(.secondary); Text(artist) }
                }
                if !sacd.discCatalogNumber.isEmpty {
                    GridRow { Text("Catalog number").foregroundStyle(.secondary); Text(sacd.discCatalogNumber) }
                }
                if let date = sacd.discDate {
                    GridRow { Text("Disc date").foregroundStyle(.secondary); Text(date) }
                }
                if sacd.albumSetSize > 1 {
                    GridRow {
                        Text("Album set").foregroundStyle(.secondary)
                        Text("Disc \(sacd.albumSequenceNumber) of \(sacd.albumSetSize)")
                    }
                }
                ForEach(sacd.areas, id: \.tocSector) { area in
                    GridRow {
                        Text(area.isMultichannel ? "Multichannel area" : "Stereo area").foregroundStyle(.secondary)
                        Text("\(area.channelCount) ch · \(area.isDST ? "DST" : "DSD") · \(area.trackCount) tracks · \(Self.duration(area.playTimeSeconds))")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private func discSection(_ disc: DetectedDisc, showNumber: Bool) -> some View {
        GroupBox(showNumber ? "Disc \(disc.number)" : "Tracks") {
            VStack(alignment: .leading, spacing: 8) {
                if let cue = disc.cue {
                    cueSummary(cue, url: disc.cueURL)
                }
                if let image = disc.imageFile, let cue = disc.cue {
                    Text("Image: \(image.fileName) (\(ByteCountFormatter.string(fromByteCount: image.fileSize, countStyle: .file)))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    trackTable(cueTracks: cue.audioTracks)
                } else {
                    trackTable(files: disc.trackFiles, cue: disc.cue)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private func cueSummary(_ cue: CueSheet, url: URL?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                Text(url?.lastPathComponent ?? "CUE")
                Text("(\(cue.encodingName))").foregroundStyle(.tertiary)
            }
            .font(.callout)
            let hints: [(String, String?)] = [
                ("Performer", cue.performer),
                ("Title", cue.title),
                ("Date", cue.date),
                ("Genre", cue.genre),
                ("DiscID", cue.discID),
                ("Barcode", cue.barcodeHint),
                ("Catalog #", cue.catalogNumberHints.isEmpty ? nil : cue.catalogNumberHints.joined(separator: ", ")),
            ]
            ForEach(hints.filter { $0.1 != nil }, id: \.0) { pair in
                HStack(spacing: 4) {
                    Text(pair.0 + ":").foregroundStyle(.secondary)
                    Text(pair.1 ?? "")
                }
                .font(.caption)
            }
        }
    }

    private func trackTable(cueTracks: [CueTrack]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(cueTracks, id: \.number) { track in
                HStack {
                    Text(String(format: "%02d", track.number))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .trailing)
                    Text(track.title ?? "Track \(track.number)")
                        .lineLimit(1)
                    Spacer()
                    if let start = track.start {
                        Text(start.msfString)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
            }
        }
    }

    private func trackTable(files: [DetectedTrackFile], cue: CueSheet?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(files.enumerated()), id: \.element.url) { index, file in
                let cueTrack = cue?.audioTracks.first { $0.number == index + 1 }
                HStack {
                    Text(String(format: "%02d", index + 1))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .trailing)
                    Text(cueTrack?.title ?? file.fileName)
                        .lineLimit(1)
                    Spacer()
                    Text(file.format.displayName)
                        .foregroundStyle(.tertiary)
                    Text(ByteCountFormatter.string(fromByteCount: file.fileSize, countStyle: .file))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .trailing)
                }
                .font(.callout)
                .help(file.url.path)
            }
        }
    }

    private func artworkSection(_ files: [URL]) -> some View {
        GroupBox("Artwork (\(files.count))") {
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(files, id: \.self) { url in
                        VStack(spacing: 4) {
                            ArtworkThumbnail(url: url, side: 110)
                            Text(url.lastPathComponent)
                                .font(.caption2)
                                .lineLimit(1)
                                .frame(width: 110)
                        }
                        .help(url.path)
                    }
                }
                .padding(4)
            }
        }
    }

    private func issuesSection(_ issues: [ScanIssue]) -> some View {
        GroupBox("Notes") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(issues, id: \.self) { issue in
                    Label {
                        Text("\(issue.url.lastPathComponent): \(issue.message)")
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    .font(.callout)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private static func duration(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

// Decodes a downscaled thumbnail off the main thread with ImageIO so a
// 30 MB booklet scan never blocks the UI.
struct ArtworkThumbnail: View {
    let url: URL
    let side: CGFloat

    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: url) {
            let target = Int(side * 2)
            let loaded = await Task.detached(priority: .utility) {
                Self.thumbnail(for: url, maxPixel: target)
            }.value
            image = loaded
        }
    }

    nonisolated static func thumbnail(for url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
