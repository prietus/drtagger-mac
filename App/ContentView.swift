import LibraryKit
import SACDKit
import SplitKit
import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(LibraryController.self) private var library
    @Environment(DiscService.self) private var disc
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var library = library
        NavigationSplitView {
            QueueSidebar(selection: $library.selection)
                .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 520)
        } detail: {
            if let record = library.record(id: library.selection) {
                AlbumInspectorView(record: record)
                    .id(record.persistentModelID)
            } else {
                ContentUnavailableView(
                    "No Album Selected",
                    systemImage: "opticaldisc",
                    description: Text("Add folders with SACD ISOs, CD images or album tracks to get started.")
                )
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if library.isScanning {
                    ProgressView()
                        .controlSize(.small)
                        .help(library.currentFolder ?? String(localized: "Scanning…"))
                }
                Button {
                    if let record = library.record(id: library.selection) {
                        Task { await library.rescan(record) }
                    }
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .disabled(library.selection == nil || library.isScanning)
                .help("Scan the selected album's folder again")

                Button {
                    library.presentAddPanel()
                } label: {
                    Label("Add Folders…", systemImage: "plus")
                }
                .disabled(library.isScanning)
                .help("Add folders or image files to the queue")
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !library.isScanning else { return false }
            Task { await library.addRoots(urls) }
            return true
        }
        .navigationTitle("drtagger")
        .task {
            await library.importLaunchArguments()
            await splitFromLaunchArguments()
            await extractFromLaunchArguments()
        }
    }
}

extension ContentView {
    // `--split-into <folder>` splits every CUE-based album in the store after
    // the launch scan. Used to exercise the whole pipeline from scripts.
    func splitFromLaunchArguments(_ arguments: [String] = CommandLine.arguments) async {
        guard let index = arguments.firstIndex(of: "--split-into"), index + 1 < arguments.count else { return }
        let destination = URL(fileURLWithPath: NSString(string: arguments[index + 1]).expandingTildeInPath, isDirectory: true)
        for record in library.allRecords() where record.isSplittable {
            var options = SplitOptions()
            options.overwriteExisting = true
            await disc.split(record, into: destination, locator: settings.ffmpegLocator, options: options)
        }
    }
}

extension ContentView {
    // `--extract-into <folder>` extracts every SACD ISO in the store.
    func extractFromLaunchArguments(_ arguments: [String] = CommandLine.arguments) async {
        guard let index = arguments.firstIndex(of: "--extract-into"), index + 1 < arguments.count else { return }
        let destination = URL(fileURLWithPath: NSString(string: arguments[index + 1]).expandingTildeInPath, isDirectory: true)
        for record in library.allRecords() where record.kind == .sacdISO && !record.hasDST {
            var options = SACDExtractOptions()
            options.overwriteExisting = true
            options.pausePolicy = settings.sacdPausePolicy
            await disc.extractSACD(record, into: destination, multichannel: settings.extractMultichannel, options: options)
        }
    }
}

// Left column: every album in the store, newest first.
struct QueueSidebar: View {
    @Environment(LibraryController.self) private var library
    @Query(sort: \AlbumRecord.addedAt, order: .reverse) private var albums: [AlbumRecord]
    @Binding var selection: PersistentIdentifier?
    @State private var search = ""

    private var filtered: [AlbumRecord] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return albums }
        return albums.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(q)
                || ($0.artistHint?.localizedCaseInsensitiveContains(q) ?? false)
                || $0.path.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(filtered) { record in
                QueueRow(record: record)
                    .tag(record.persistentModelID)
                    .contextMenu {
                        Button("Rescan") {
                            Task { await library.rescan(record) }
                        }
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([record.url])
                        }
                        Divider()
                        Button("Remove from Queue", role: .destructive) {
                            library.remove([record])
                        }
                    }
            }
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Filter albums")
        .onDeleteCommand {
            if let record = library.record(id: selection) {
                library.remove([record])
            }
        }
        .overlay {
            if albums.isEmpty && !library.isScanning {
                ContentUnavailableView {
                    Label("Queue is Empty", systemImage: "tray")
                } description: {
                    Text("Drop folders here, or use Add Folders… (⌘O).")
                } actions: {
                    Button("Add Folders…") {
                        library.presentAddPanel()
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            QueueStatusBar(count: albums.count)
        }
    }
}

struct QueueStatusBar: View {
    @Environment(LibraryController.self) private var library
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            if library.isScanning {
                ProgressView().controlSize(.mini)
                Text(library.currentFolder.map { String(localized: "Scanning \($0)…") } ?? String(localized: "Scanning…"))
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if let summary = library.lastScanSummary {
                Text(summary)
                    .lineLimit(1)
            } else {
                Text(count == 1 ? String(localized: "1 album") : String(localized: "\(count) albums"))
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

struct QueueRow: View {
    let record: AlbumRecord

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: kindImage)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.displayTitle)
                    .lineLimit(1)
                if let artist = record.artistHint, !artist.isEmpty {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(record.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: record.state.systemImage)
                .foregroundStyle(stateColor)
                .help(record.state.label)
        }
        .padding(.vertical, 2)
    }

    private var kindImage: String {
        switch record.kind {
        case .sacdISO: return "opticaldiscdrive"
        case .cueImage: return "opticaldisc"
        case .cueMultiFile: return "list.bullet.rectangle"
        case .trackFolder: return "folder"
        }
    }

    private var stateColor: Color {
        switch record.state {
        case .confident, .done: return .green
        case .needsReview: return .orange
        case .error: return .red
        case .scanning, .identifying, .applying: return .accentColor
        default: return .secondary
        }
    }
}
