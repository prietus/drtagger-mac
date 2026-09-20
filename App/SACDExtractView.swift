import LibraryKit
import SACDKit
import SwiftUI

// Inspector section for SACD images: the extract action and its results.
struct SACDExtractView: View {
    let record: AlbumRecord
    let sacd: SACDInfo
    @Environment(DiscService.self) private var disc
    @Environment(AppSettings.self) private var settings

    private var stereoIsDST: Bool { sacd.stereoArea?.isDST ?? false }

    var body: some View {
        GroupBox("Extract") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    if !record.sacdOutcomes.isEmpty {
                        let ok = record.sacdOutcomes.allSatisfy(\.verified)
                        let count = record.sacdOutcomes.reduce(0) { $0 + $1.tracks.count }
                        Label(ok ? "\(count) DSF tracks written and verified" : "Extraction finished with problems",
                              systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(ok ? .green : .orange)
                    } else if stereoIsDST {
                        Label("DST-compressed disc: extraction needs the DST decoder (coming in this phase)", systemImage: "hourglass")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Not extracted yet").font(.callout).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button(record.sacdOutcomes.isEmpty ? "Extract to Library…" : "Extract Again…") {
                        startExtract()
                    }
                    .disabled(disc.isBusy(record) || stereoIsDST)
                }
                Text(policyDescription)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
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
                ForEach(Array(record.sacdOutcomes.enumerated()), id: \.offset) { _, outcome in
                    outcomeRows(outcome)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var policyDescription: String {
        var parts: [String] = []
        parts.append(settings.sacdPausePolicy == .drop
                     ? String(localized: "Pauses between tracks are dropped")
                     : String(localized: "Pauses between tracks stay with the previous track"))
        if sacd.multichannelArea != nil {
            parts.append(settings.extractMultichannel
                         ? String(localized: "multichannel area included")
                         : String(localized: "stereo area only"))
        }
        return parts.joined(separator: " · ")
    }

    private func outcomeRows(_ outcome: SACDExtractOutcome) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(outcome.isMultichannel ? "Multichannel (\(outcome.channelCount) ch)" : "Stereo")
                    .font(.caption)
                    .bold()
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
            Text("DSF · \(String(format: "%.1f", outcome.elapsedSeconds)) s · \(outcome.droppedLeadInFrames) lead-in frames skipped\(outcome.droppedPauseFrames > 0 ? " · \(outcome.droppedPauseFrames) pause frames dropped" : "")")
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
                    Text("\(t.frames) frames · \(ByteCountFormatter.string(fromByteCount: Int64(t.fileSize), countStyle: .file))")
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                .font(.caption)
            }
            ForEach(outcome.warnings, id: \.self) { w in
                Label(w, systemImage: "info.circle").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func startExtract() {
        let destination: URL
        if let root = settings.libraryRootURL {
            destination = root
        } else if let picked = FolderPicker.pickFolder(message: String(localized: "Choose the library folder where extracted tracks are written.")) {
            settings.libraryRoot = picked.path
            destination = picked
        } else {
            return
        }
        var options = SACDExtractOptions()
        options.overwriteExisting = !record.sacdOutcomes.isEmpty
        options.pausePolicy = settings.sacdPausePolicy
        Task { await disc.extractSACD(record, into: destination, multichannel: settings.extractMultichannel, options: options) }
    }
}
