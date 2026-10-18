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
            HStack {
                Text("\(candidates.count) album(s) to process").font(.callout)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start") {
                    batch.start(mode: mode)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(candidates.isEmpty || settings.libraryRoot.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 560)
        .onAppear { mode = batch.mode }
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
            if let a = batch.networkActivity ?? batch.cpuActivity {
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
