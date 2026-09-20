import SwiftUI

struct ContentView: View {
    @Environment(AlbumQueue.self) private var queue

    var body: some View {
        @Bindable var queue = queue
        NavigationSplitView {
            QueueSidebar(selection: $queue.selection)
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 480)
        } detail: {
            if let album = queue.album(id: queue.selection) {
                AlbumInspectorView(album: album)
            } else {
                ContentUnavailableView(
                    "No Album Selected",
                    systemImage: "opticaldisc",
                    description: Text("Add folders with SACD ISOs, CD images or album tracks to get started.")
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    queue.presentAddPanel()
                } label: {
                    Label("Add Folders…", systemImage: "plus")
                }
                .help("Add folders or image files to the queue")
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            !queue.add(urls: urls).isEmpty
        }
        .navigationTitle("drtagger")
    }
}

// Left column: the album queue with per-entry state.
struct QueueSidebar: View {
    @Environment(AlbumQueue.self) private var queue
    @Binding var selection: QueuedAlbum.ID?

    var body: some View {
        List(selection: $selection) {
            ForEach(queue.albums) { album in
                QueueRow(album: album)
                    .tag(album.id)
                    .contextMenu {
                        Button("Remove from Queue") {
                            queue.remove(ids: [album.id])
                        }
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([album.url])
                        }
                    }
            }
        }
        .onDeleteCommand {
            if let sel = selection {
                queue.remove(ids: [sel])
            }
        }
        .overlay {
            if queue.albums.isEmpty {
                ContentUnavailableView {
                    Label("Queue is Empty", systemImage: "tray")
                } description: {
                    Text("Drop folders here, or use Add Folders… (⌘O).")
                } actions: {
                    Button("Add Folders…") {
                        queue.presentAddPanel()
                    }
                }
            }
        }
    }
}

struct QueueRow: View {
    let album: QueuedAlbum

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: album.state.systemImage)
                .foregroundStyle(iconColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(album.displayName)
                    .lineLimit(1)
                Text(album.state.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var iconColor: Color {
        switch album.state {
        case .confident, .done: return .green
        case .needsReview: return .orange
        case .error: return .red
        default: return .secondary
        }
    }
}

// Right column placeholder. Phase 1 replaces this with the real inspector
// (candidates, tag diff, artwork, log).
struct AlbumInspectorView: View {
    let album: QueuedAlbum

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "opticaldisc")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading) {
                    Text(album.displayName)
                        .font(.title2)
                        .bold()
                    Text(album.url.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Divider()
            LabeledContent("State", value: album.state.label)
            LabeledContent("Added", value: album.addedAt.formatted(date: .abbreviated, time: .shortened))
            Spacer()
            Text("Scanning and identification arrive in the next phase.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

#Preview {
    ContentView()
        .environment(AlbumQueue())
        .environment(AppSettings())
}
