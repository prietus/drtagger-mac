import AppKit
import ImageIO
import SwiftUI

// A cover or scan to look at closely: a local file or bytes from a provider.
struct ImageViewerItem: Identifiable {
    let id = UUID()
    let title: String
    let url: URL?
    let data: Data?
    let subtitle: String?
}

// Simple viewer sheet: the image fitted to most of the screen, its pixel
// size, and Show in Finder for local files.
struct ImageViewerSheet: View {
    let item: ImageViewerItem
    @Environment(\.dismiss) private var dismiss
    @State private var image: CGImage?
    @State private var pixelSize: (Int, Int)?

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.headline).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 6) {
                        if let (w, h) = pixelSize { Text("\(w) × \(h) px") }
                        if let s = item.subtitle { Text("· " + s) }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if let url = item.url {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Group {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(16)
        .frame(minWidth: 500, minHeight: 500)
        .frame(idealWidth: viewerSide, idealHeight: viewerSide + 60)
        .task { await load() }
    }

    private var viewerSide: CGFloat {
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1200, height: 900)
        return min(screen.width * 0.8, screen.height * 0.85 - 60)
    }

    private func load() async {
        let source: CGImageSource?
        if let data = item.data {
            source = CGImageSourceCreateWithData(data as CFData, nil)
        } else if let url = item.url {
            source = CGImageSourceCreateWithURL(url as CFURL, nil)
        } else {
            source = nil
        }
        guard let source else { return }
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
            pixelSize = (w, h)
        }
        // Decode at screen size, not at scan size: a 6000 px booklet page
        // must not cost 150 MB.
        let maxPixel = Int((NSScreen.main?.backingScaleFactor ?? 2) * 1400)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
        ]
        image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
