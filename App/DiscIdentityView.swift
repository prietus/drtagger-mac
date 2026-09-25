import LibraryKit
import ProviderKit
import SplitKit
import SwiftUI

// Inspector section for CUE-based albums: disc IDs from the TOC, CUETools
// DB status, and the split action with its verified results.
struct DiscIdentityView: View {
    let record: AlbumRecord
    @Environment(DiscService.self) private var disc
    @Environment(AppSettings.self) private var settings

    var body: some View {
        GroupBox("Disc") {
            VStack(alignment: .leading, spacing: 10) {
                identityRows
                Divider()
                ctdbRows
                if record.isSplittable {
                    Divider()
                    splitRows
                }
                if let activity = disc.activity(for: record) {
                    HStack(spacing: 8) {
                        if let f = activity.fraction {
                            ProgressView(value: f).frame(width: 160)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                        Text(activity.message).font(.callout).foregroundStyle(.secondary)
                    }
                }
                if let error = disc.error(for: record) {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        .task(id: record.path) {
            if record.toc == nil, !disc.isBusy(record) {
                await disc.computeTOC(record, locator: settings.ffmpegLocator)
            }
        }
    }

    // MARK: Identity

    @ViewBuilder
    private var identityRows: some View {
        if let toc = record.toc {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Text("MusicBrainz Disc ID").foregroundStyle(.secondary)
                    Text(toc.musicBrainzDiscID).monospaced().textSelection(.enabled)
                }
                GridRow {
                    Text("FreeDB ID").foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text(toc.freeDBDiscID).monospaced().textSelection(.enabled)
                        if let rem = record.detected?.discs.first?.cue?.discID?.uppercased() {
                            Image(systemName: rem == toc.freeDBDiscID ? "checkmark.circle.fill" : "exclamationmark.circle")
                                .foregroundStyle(rem == toc.freeDBDiscID ? .green : .orange)
                                .help(rem == toc.freeDBDiscID ? "Matches the CUE's REM DISCID" : "CUE says \(rem)")
                        }
                    }
                }
                GridRow {
                    Text("TOC").foregroundStyle(.secondary)
                    Text("\(toc.trackCount) tracks · \(toc.ctdbTOCString)")
                        .font(.caption)
                        .monospaced()
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            .font(.callout)
        } else {
            Text("Disc layout not read yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: CUETools DB

    @ViewBuilder
    private var ctdbRows: some View {
        HStack(spacing: 10) {
            Text("CUETools DB").font(.callout).foregroundStyle(.secondary)
            if let report = record.ctdbReport {
                if report.isKnownDisc {
                    Label("\(report.entryCount) rips known, confidence \(report.totalConfidence)", systemImage: "checkmark.seal")
                        .font(.callout)
                } else {
                    Label("Disc not in the database", systemImage: "questionmark.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(record.ctdbReport == nil ? "Check" : "Re-check") {
                Task { await disc.checkCUEToolsDB(record, locator: settings.ffmpegLocator) }
            }
            .disabled(disc.isBusy(record))
        }
        if let report = record.ctdbReport {
            if let v = report.verification {
                verificationRow(v)
            }
            if !report.metadata.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Releases with this TOC").font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(report.metadata.prefix(6).enumerated()), id: \.offset) { _, m in
                        HStack(spacing: 6) {
                            Image(systemName: m.source == "musicbrainz" ? "music.note.list" : "text.book.closed")
                                .foregroundStyle(.secondary)
                            Text("\(m.artist) – \(m.album)")
                                .lineLimit(1)
                            if let y = m.year { Text(y).foregroundStyle(.secondary) }
                            if let c = m.country { Text(c).foregroundStyle(.tertiary) }
                            if let cat = m.catalogNumber { Text(cat).foregroundStyle(.tertiary) }
                            if let b = m.barcode { Text(b).monospaced().foregroundStyle(.tertiary) }
                        }
                        .font(.caption)
                    }
                }
            }
        }
    }

    private func verificationRow(_ v: CUEToolsDBClient.Verification) -> some View {
        HStack(spacing: 6) {
            if v.allTracksMatch {
                Label("All \(v.tracks.count) tracks match a known rip (confidence \(v.totalConfidence))", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if v.matchedTrackCount > 0 {
                Label("\(v.matchedTrackCount) of \(v.tracks.count) tracks match; the others differ (offset or damage)", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
            } else {
                Label("No track matches a known rip", systemImage: "xmark.circle")
                    .foregroundStyle(.red)
            }
        }
        .font(.callout)
    }

    // MARK: Split

    @ViewBuilder
    private var splitRows: some View {
        HStack(spacing: 10) {
            Text("Split").font(.callout).foregroundStyle(.secondary)
            if !record.splitOutcomes.isEmpty {
                let outcomes = record.splitOutcomes
                let ok = outcomes.allSatisfy(\.verified)
                let count = outcomes.reduce(0) { $0 + $1.tracks.count }
                Label(ok ? (outcomes.count > 1 ? "\(count) tracks on \(outcomes.count) discs written and verified" : "\(count) tracks written and verified") : "Split finished with problems",
                      systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(ok ? .green : .orange)
            } else {
                Text("Not split yet").font(.callout).foregroundStyle(.tertiary)
            }
            Spacer()
            Button(record.splitOutcome == nil ? "Split to Library…" : "Split Again…") {
                startSplit()
            }
            .disabled(disc.isBusy(record))
        }
        ForEach(Array(record.splitOutcomes.enumerated()), id: \.offset) { _, outcome in
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(outcome.outputFolder.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([outcome.outputFolder])
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
                }
                Text("\(outcome.format.description) · FLAC · \(String(format: "%.1f", outcome.elapsedSeconds)) s")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                ForEach(outcome.tracks, id: \.number) { t in
                    HStack(spacing: 6) {
                        Image(systemName: t.verified ? "checkmark" : "xmark")
                            .foregroundStyle(t.verified ? .green : .red)
                            .frame(width: 14)
                        Text(String(format: "%02d", t.number)).monospacedDigit().foregroundStyle(.secondary)
                        Text(t.url.lastPathComponent).lineLimit(1)
                        Spacer()
                        if let crc = t.ctdbCRC32 {
                            Text(crc.hex8).monospaced().foregroundStyle(.tertiary)
                        }
                    }
                    .font(.caption)
                }
                ForEach(outcome.warnings, id: \.self) { w in
                    Label(w, systemImage: "info.circle").font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private func startSplit() {
        let destination: URL
        if let root = settings.libraryRootURL {
            destination = root
        } else if let picked = FolderPicker.pickFolder(message: String(localized: "Choose the library folder where split tracks are written.")) {
            settings.libraryRoot = picked.path
            destination = picked
        } else {
            return
        }
        var options = SplitOptions()
        options.overwriteExisting = record.splitOutcome != nil
        options.albumFolderTemplate = settings.albumFolderTemplate
        options.trackFileTemplate = settings.trackFileTemplate
        options.asciiFileNames = settings.asciiFileNames
        Task { await disc.split(record, into: destination, locator: settings.ffmpegLocator, options: options, trashOriginals: settings.moveOriginalsToTrash) }
    }
}
