import LibraryKit
import SACDKit
import SplitKit
import SwiftUI

// Inspector section for multi-disc releases: the discs of a set (several
// records) or of a folder album (CD1/CD2…), with grouping controls and
// one-click split/extract of every disc.
struct ReleaseSetView: View {
    let record: AlbumRecord
    @Environment(LibraryController.self) private var library
    @Environment(DiscService.self) private var disc
    @Environment(AppSettings.self) private var settings

    private var members: [AlbumRecord] { library.members(of: record) }
    private var siblings: [AlbumRecord] { record.setID == nil ? library.siblingCandidates(of: record) : [] }
    private var folderDiscs: [DetectedDisc] { (record.detected?.discs ?? []).sorted { $0.number < $1.number } }
    private var isVisible: Bool { record.setID != nil || folderDiscs.count > 1 || !siblings.isEmpty || (record.detected?.discPosition?.total ?? 0) > 1 }

    var body: some View {
        if isVisible {
            GroupBox("Release set") {
                VStack(alignment: .leading, spacing: 8) {
                    header
                    if record.setID != nil {
                        ForEach(members, id: \.path) { m in memberRow(m) }
                    } else if folderDiscs.count > 1 {
                        ForEach(folderDiscs, id: \.number) { d in
                            HStack(spacing: 8) {
                                Text("Disc \(d.number)").font(.callout).frame(width: 60, alignment: .leading)
                                Text(d.cueURL?.lastPathComponent ?? d.folder.lastPathComponent).font(.callout).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text("\(d.trackCount) tracks").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if record.setID != nil {
                let total = record.setTotal ?? members.count
                let missing = total > members.count
                Label(missing ? "\(members.count) of \(total) discs in the queue" : "\(members.count) discs, one release",
                      systemImage: missing ? "exclamationmark.triangle" : "square.stack.3d.up")
                    .foregroundStyle(missing ? .orange : .secondary)
            } else if folderDiscs.count > 1 {
                Label("\(folderDiscs.count) discs in this folder", systemImage: "square.stack.3d.up").foregroundStyle(.secondary)
            } else if let p = record.detected?.discPosition, let total = p.total {
                Label("This is disc \(p.number) of \(total); the other discs are not in the queue", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            Spacer()
            if !siblings.isEmpty {
                Button("Group with \(siblings.count) sibling(s)") { library.group([record] + siblings) }
                    .help("Treat the discs found in the same folder as one release")
            }
            if record.setID != nil {
                if members.contains(where: { $0.isSplittable && $0.splitOutcomes.isEmpty }) {
                    Button("Split All Discs…") { runAll(split: true) }.disabled(members.contains { disc.isBusy($0) })
                }
                if members.contains(where: { $0.kind == .sacdISO && $0.sacdOutcomes.isEmpty }) {
                    Button("Extract All Discs…") { runAll(split: false) }.disabled(members.contains { disc.isBusy($0) })
                }
                Button("Ungroup") { library.ungroup(record) }.disabled(members.contains { disc.isBusy($0) })
            }
        }
        .font(.callout)
    }

    private func memberRow(_ m: AlbumRecord) -> some View {
        HStack(spacing: 8) {
            Stepper(value: Binding(get: { m.setPosition ?? 1 }, set: { library.setPosition(m, to: $0) }), in: 1...99) {
                Text("Disc \(m.setPosition ?? 1)").font(.callout).monospacedDigit()
            }
            .frame(width: 110, alignment: .leading)
            Text(m.displayTitle).font(.callout).lineLimit(1).truncationMode(.middle)
            if m.path == record.path { Text("(this)").font(.caption).foregroundStyle(.tertiary) }
            Spacer()
            Text("\(m.trackCount) tracks").font(.caption).foregroundStyle(.secondary)
            Image(systemName: m.state.systemImage).foregroundStyle(.secondary).help(m.state.label)
            Button {
                library.selection = m.persistentModelID
            } label: { Image(systemName: "arrow.right.circle") }
                .buttonStyle(.borderless)
                .help("Show this disc")
        }
    }

    // Split or extract every member that still needs it, into the library root.
    private func runAll(split: Bool) {
        guard let root = settings.libraryRootURL ?? FolderPicker.pickFolder(message: String(localized: "Choose the library folder where the discs are written.")) else { return }
        Task {
            for m in members {
                if split, m.isSplittable, m.splitOutcomes.isEmpty {
                    var options = SplitOptions()
                    options.albumFolderTemplate = settings.albumFolderTemplate
                    options.trackFileTemplate = settings.trackFileTemplate
                    options.asciiFileNames = settings.asciiFileNames
                    await disc.split(m, into: root, locator: settings.ffmpegLocator, options: options, trashOriginals: settings.moveOriginalsToTrash)
                } else if !split, m.kind == .sacdISO, m.sacdOutcomes.isEmpty {
                    var options = SACDExtractOptions()
                    options.pausePolicy = settings.sacdPausePolicy
                    options.albumFolderTemplate = settings.albumFolderTemplate
                    options.trackFileTemplate = settings.trackFileTemplate
                    options.asciiFileNames = settings.asciiFileNames
                    await disc.extractSACD(m, into: root, multichannel: settings.extractMultichannel, options: options, trashOriginals: settings.moveOriginalsToTrash)
                }
            }
        }
    }
}
