import AppKit
import ProviderKit
import UniformTypeIdentifiers
import SwiftUI

// Which albums the sidebar shows while a batch exists.
enum BatchFilter: String, CaseIterable, Identifiable {
    case all, review, failed, done
    var id: String { rawValue }

    func matches(_ r: AlbumRecord) -> Bool {
        switch self {
        case .all: return true
        case .review: return r.batchStatus == .review
        case .failed: return r.batchStatus == .failed
        case .done: return r.batchStatus == .done
        }
    }
}

struct BatchCounts {
    var total = 0, done = 0, review = 0, failed = 0, open = 0

    init(_ records: [AlbumRecord]) {
        for r in records {
            guard let s = r.batchStatus else { continue }
            total += 1
            switch s {
            case .done: done += 1
            case .review: review += 1
            case .failed: failed += 1
            default: open += 1
            }
        }
    }

    var finished: Int { done + review + failed }
}

// Start a batch: which albums, where they end up.
struct BatchStartSheet: View {
    @Environment(BatchRunner.self) private var batch
    @Environment(LibraryController.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var mode: BatchRunner.Mode = .importToLibrary
    @State private var dryRun = true

    private var candidates: [AlbumRecord] {
        library.allRecords().filter { library.isLeader($0) && $0.taggedAt == nil && $0.batchStatus != .done && $0.batchStatus != .review }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Process the Queue").font(.title2).bold()
            Text("Every album is identified; those with a sure match get their files, tags, cover and ReplayGain without asking. The rest are set aside for you to review, and the batch keeps going.")
                .foregroundStyle(.secondary)
            Picker("Destination", selection: $mode) {
                Text("Import to the library: tag, then move into the library layout").tag(BatchRunner.Mode.importToLibrary)
                Text("Update in place: tag the files where they are").tag(BatchRunner.Mode.updateInPlace)
            }
            .pickerStyle(.radioGroup)
            HStack(spacing: 6) {
                Image(systemName: "folder")
                Text(settings.libraryRoot.isEmpty ? String(localized: "No library folder set") : settings.libraryRoot)
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(settings.libraryRoot.isEmpty ? .orange : .secondary)
                Button("Choose…") {
                    if let url = FolderPicker.pickFolder(message: String(localized: "Choose the library folder.")) { settings.libraryRoot = url.path }
                }
            }
            .font(.callout)
            Text("SACD images and CD images always get their tracks written to the library folder. Originals are backed up, and every album can be restored afterwards.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Preview run: identify and report what would change, write nothing", isOn: $dryRun)
            Text("Albums whose files name a different release than the one found, and releases already elsewhere in the library, are always set aside for you.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("\(candidates.count) album(s) to process").font(.callout)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(dryRun ? "Start Preview" : "Start") {
                    batch.start(mode: mode, dryRun: dryRun)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(candidates.isEmpty || settings.libraryRoot.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 560)
        .onAppear { mode = batch.mode; dryRun = batch.dryRun || batch.startedAt == nil }
    }
}

// Status-bar line while a batch exists.
struct BatchStatusLine: View {
    @Environment(BatchRunner.self) private var batch
    @Environment(LibraryController.self) private var library
    let counts: BatchCounts

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                ProgressView(value: Double(counts.finished), total: Double(max(1, counts.total)))
                    .frame(width: 90)
                Text("\(counts.finished)/\(counts.total)").monospacedDigit()
                if counts.review > 0 { Label("\(counts.review)", systemImage: "questionmark.circle").foregroundStyle(.orange).help("To review") }
                if counts.failed > 0 { Label("\(counts.failed)", systemImage: "exclamationmark.triangle").foregroundStyle(.red).help("Errors") }
                Spacer()
                if batch.isRunning {
                    Button(batch.stopping ? "Stopping…" : "Stop") { batch.stop() }
                        .buttonStyle(.borderless).disabled(batch.stopping)
                } else if counts.open > 0 {
                    Button("Resume") { batch.resume() }.buttonStyle(.borderless)
                } else {
                    Button("Close Batch") { batch.clear() }.buttonStyle(.borderless)
                        .help("Forget the batch statuses; the albums stay in the queue")
                }
            }
            HStack(spacing: 6) {
                if batch.dryRun { Text("Preview").bold().foregroundStyle(.orange) }
                if let eta = batch.estimatedRemaining(open: counts.open, finished: counts.finished) {
                    Text("About \(Duration.seconds(eta).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))) left").foregroundStyle(.tertiary)
                }
            }
            if let a = batch.indexing ?? batch.networkActivity ?? batch.cpuActivity {
                Text(a).lineLimit(1).truncationMode(.middle).foregroundStyle(.tertiary)
            }
        }
    }
}

// Inspector banner for an album the batch set aside.
struct BatchReviewBanner: View {
    let record: AlbumRecord
    @Environment(LibraryController.self) private var library

    var body: some View {
        if let status = record.batchStatus, status == .review || status == .failed {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: status == .review ? "questionmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(status == .review ? .orange : .red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(status == .review ? "Set aside for review" : "The batch could not finish this album").bold()
                    if let note = record.batchNote { Text(note).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                }
                Spacer()
                Button("Leave As Is") {
                    for m in library.members(of: record) { m.batchStatus = .done; m.batchNote = String(localized: "Left as is") }
                    selectNext()
                }
                .help("Mark it done without writing anything")
                Button("Next to Review") { selectNext() }
                    .disabled(nextRecord == nil)
            }
            .padding(12)
            .background((status == .review ? Color.orange : Color.red).opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var nextRecord: AlbumRecord? {
        let all = library.allRecords().sorted(by: BatchRunner.queueOrder).filter { $0.batchStatus == .review || $0.batchStatus == .failed }
        guard !all.isEmpty else { return nil }
        if let i = all.firstIndex(where: { $0.path == record.path }), i + 1 < all.count { return all[i + 1] }
        return all.first { $0.path != record.path }
    }

    private func selectNext() {
        if let next = nextRecord { library.selection = next.persistentModelID }
    }
}


// The batch at a glance: one row per album, sortable, with the release
// chosen, the confidence and what happened. Double-click opens the album.
struct BatchTableView: View {
    @Environment(LibraryController.self) private var library
    @Environment(BatchRunner.self) private var batch
    let onOpen: (AlbumRecord) -> Void
    @State private var filter: BatchFilter = .all
    @State private var selection = Set<String>()
    @State private var sortOrder = [KeyPathComparator(\BatchRow.order)]

    var body: some View {
        let all = rows
        let counts = BatchCounts(library.allRecords())
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text(batch.dryRun ? "Batch preview" : "Batch").font(.title3).bold()
                ProgressView(value: Double(counts.finished), total: Double(max(1, counts.total))).frame(maxWidth: 200)
                Text("\(counts.finished) of \(counts.total)").monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Picker("Show", selection: $filter) {
                    Text("All").tag(BatchFilter.all)
                    Text("Review \(counts.review)").tag(BatchFilter.review)
                    Text("Errors \(counts.failed)").tag(BatchFilter.failed)
                    Text("Done \(counts.done)").tag(BatchFilter.done)
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 360)
                Button("Export Report…") { exportReport(all) }
            }
            Table(all.filter { $0.matches(filter) }.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Status", value: \BatchRow.statusText) { row in
                    Label(row.statusText, systemImage: row.icon).foregroundStyle(row.color)
                }
                .width(min: 90, ideal: 110)
                TableColumn("Album", value: \BatchRow.album) { row in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.album).lineLimit(1)
                        Text(row.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .width(min: 180, ideal: 260)
                TableColumn("Release", value: \BatchRow.release) { row in
                    Text(row.release).lineLimit(2).foregroundStyle(.secondary)
                }
                .width(min: 160, ideal: 260)
                TableColumn("Match", value: \BatchRow.confidence) { row in Text(row.confidence) }
                    .width(min: 60, ideal: 80)
                TableColumn("Note", value: \BatchRow.note) { row in
                    Text(row.note).lineLimit(2).foregroundStyle(.secondary).help(row.note)
                }
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first, let record = library.fetch(path: id) {
                    Button("Open Album") { onOpen(record) }
                }
            } primaryAction: { ids in
                if let id = ids.first, let record = library.fetch(path: id) { onOpen(record) }
            }
        }
        .padding(18)
    }

    private var rows: [BatchRow] {
        library.allRecords().sorted(by: BatchRunner.queueOrder).enumerated().compactMap { i, r in
            r.batchStatus == nil ? nil : BatchRow(record: r, order: i)
        }
    }

    private func exportReport(_ rows: [BatchRow]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "drtagger batch \(Date().formatted(.iso8601.year().month().day())).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var csv = "status,artist,album,path,release,release_id,match,note\n"
        for r in rows {
            csv += [r.statusText, r.artist, r.album, r.id, r.release, r.releaseID, r.confidence, r.note].map(q).joined(separator: ",") + "\n"
        }
        try? csv.write(to: url, atomically: true, encoding: .utf8)
    }
}

// A snapshot of one album for the table: plain values, so the table can
// sort by key paths.
struct BatchRow: Identifiable, Sendable {
    enum Kind: Sendable { case done, review, failed, working, pending }
    let id: String
    let order: Int
    let album: String
    let artist: String
    let release: String
    let releaseID: String
    let confidence: String
    let note: String
    let kind: Kind

    @MainActor
    init(record r: AlbumRecord, order: Int) {
        id = r.path
        self.order = order
        album = r.displayTitle
        artist = r.artistHint ?? ""
        let c = TagService.chosenCandidate(r)
        release = c.map(BatchRunner.describe) ?? ""
        releaseID = c.map(BatchRunner.releaseKey) ?? ""
        confidence = r.identification?.best?.confidence.rawValue ?? ""
        note = r.batchNote ?? ""
        switch r.batchStatus {
        case .done: kind = .done
        case .review: kind = .review
        case .failed: kind = .failed
        case .working: kind = .working
        default: kind = .pending
        }
    }

    var statusText: String {
        switch kind {
        case .done: return String(localized: "Done")
        case .review: return String(localized: "Review")
        case .failed: return String(localized: "Error")
        case .working: return String(localized: "Working")
        case .pending: return String(localized: "Pending")
        }
    }
    var icon: String {
        switch kind {
        case .done: return "checkmark.circle.fill"
        case .review: return "questionmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .working: return "gearshape.fill"
        case .pending: return "circle"
        }
    }
    var color: Color {
        switch kind {
        case .done: return .green
        case .review: return .orange
        case .failed: return .red
        case .working: return .accentColor
        case .pending: return .secondary
        }
    }

    func matches(_ filter: BatchFilter) -> Bool {
        switch filter {
        case .all: return true
        case .review: return kind == .review
        case .failed: return kind == .failed
        case .done: return kind == .done
        }
    }
}
