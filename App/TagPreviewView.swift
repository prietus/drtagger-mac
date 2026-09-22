import AppKit
import IdentifyKit
import SwiftUI
import TagKit

// Inspector section: what Apply will write, field by field, with locks,
// the cover to embed, and Restore for files already written.
struct TagPreviewView: View {
    let record: AlbumRecord
    @Environment(TagService.self) private var tagging
    @Environment(AppSettings.self) private var settings
    @Environment(LibraryController.self) private var library
    @State private var showUnchanged = false

    private var members: [AlbumRecord] { library.members(of: record) }
    @State private var showTracks = false
    @State private var showLog = false

    private var chosenID: String? { TagService.chosenCandidate(record)?.id }
    private var hasCandidate: Bool { chosenID != nil }
    // A plan built for another release is stale: hide it until it is rebuilt.
    private var plan: TagPlan? {
        guard let p = tagging.plan(for: record), p.candidateID == chosenID else { return nil }
        return p
    }

    var body: some View {
        GroupBox("Tags") {
            VStack(alignment: .leading, spacing: 10) {
                header
                if let activity = tagging.activity(for: record) {
                    HStack(spacing: 8) {
                        if let f = activity.fraction { ProgressView(value: f).frame(width: 160) } else { ProgressView().controlSize(.small) }
                        Text(activity.message).font(.callout).foregroundStyle(.secondary)
                    }
                }
                if let error = tagging.error(for: record) {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
                }
                if let plan {
                    ForEach(plan.warnings, id: \.self) { w in
                        Label(w, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    }
                    coverRow(plan)
                    applyEffects
                    albumFields(plan)
                    tracksSection(plan)
                    if !plan.log.isEmpty {
                        DisclosureGroup("Log (\(plan.log.count) lines)", isExpanded: $showLog) {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(plan.log.enumerated()), id: \.offset) { _, line in
                                    Text(line).font(.caption).monospaced().textSelection(.enabled)
                                }
                            }
                            .padding(.top, 4)
                        }
                        .font(.caption)
                    }
                } else if !record.tagReports.isEmpty {
                    reportsSummary
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        // Picking another release re-runs the preview when one was showing.
        .onChange(of: record.selectedCandidateID) { _, _ in
            guard tagging.plan(for: record) != nil, hasCandidate, !tagging.isBusy(record) else { return }
            Task { await tagging.buildPlan(record, members: members, settings: settings) }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            if let plan {
                if plan.hasWork {
                    Label("\(plan.changedTrackCount) of \(plan.tracks.count) tracks change, \(plan.changedFieldCount) fields", systemImage: "pencil.and.list.clipboard")
                        .foregroundStyle(.orange)
                } else {
                    Label("Tags already match the release", systemImage: "checkmark.circle").foregroundStyle(.green)
                }
            } else if let at = record.taggedAt {
                Label("Tags written \(at.formatted(date: .abbreviated, time: .shortened)) · \(record.tagReports.count) files", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if !hasCandidate {
                Text("Choose a release above to preview its tags").foregroundStyle(.tertiary)
            } else {
                Text("Not previewed yet").foregroundStyle(.tertiary)
            }
            Spacer()
            if members.contains(where: { !$0.tagBackups.isEmpty }) {
                Button("Restore Originals") { Task { await tagging.restore(record, members: members) } }
                    .disabled(tagging.isBusy(record))
                    .help("Put back the metadata every file had before the first Apply")
            }
            Button(plan == nil ? "Preview Tags" : "Refresh") { Task { await tagging.buildPlan(record, members: members, settings: settings) } }
                .disabled(tagging.isBusy(record) || !hasCandidate)
            if let plan {
                Button("Apply") { Task { await tagging.apply(record, members: members, settings: settings) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(tagging.isBusy(record) || !plan.hasWork)
                    .help("Write the tags and the cover; originals are backed up and the audio is verified untouched")
            }
        }
        .font(.callout)
    }

    // What Apply does beyond the diff shown.
    private var applyEffects: some View {
        var parts: [String] = []
        if settings.computeReplayGain { parts.append(String(localized: "loudness is measured and ReplayGain / R128 tags are written")) }
        if settings.organizeAfterApply, let root = settings.libraryRootURL {
            parts.append(String(localized: "files move to \(root.lastPathComponent)/\(settings.albumFolderTemplate)/\(settings.trackFileTemplate)"))
        }
        return Group {
            if !parts.isEmpty {
                Text("On Apply, " + parts.joined(separator: "; ") + ".")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var reportsSummary: some View {
        let files = record.tagReports.count
        let withCover = record.tagReports.filter { $0.pictureCount > 0 }.count
        return Text("\(files) files written" + (withCover > 0 ? ", cover embedded in \(withCover)" : "") + ". Use Refresh to preview again.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: Cover

    private func coverRow(_ plan: TagPlan) -> some View {
        HStack(alignment: .center, spacing: 12) {
            if let cover = plan.cover, let image = NSImage(data: cover.data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 64, height: 64)
                    .overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
            }
            VStack(alignment: .leading, spacing: 4) {
                if !settings.embedFrontCover {
                    Text("Cover embedding is off in Settings").font(.callout).foregroundStyle(.secondary)
                } else if let cover = plan.cover {
                    Text("\(cover.option.label) · \(cover.width)×\(cover.height)").font(.callout)
                    Text("Embedded at \(settings.embedCoverMaxPixels) px max" + (settings.saveCoverFile ? ", full size saved as cover file" : "")).font(.caption).foregroundStyle(.secondary)
                } else if plan.artworkOptions.isEmpty {
                    Text("No artwork source found; existing pictures are kept").font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Existing pictures are kept").font(.callout).foregroundStyle(.secondary)
                }
                if !plan.artworkOptions.isEmpty {
                    Picker("Cover", selection: Binding(
                        get: { plan.coverOptionID ?? "" },
                        set: { id in Task { await tagging.chooseCover(id.isEmpty ? nil : id, for: record, settings: settings) } }
                    )) {
                        Text("Keep existing pictures").tag("")
                        ForEach(plan.artworkOptions) { option in
                            Text(option.label).tag(option.id)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(maxWidth: 360, alignment: .leading)
                }
            }
            Spacer()
        }
    }

    // MARK: Fields

    private func albumFields(_ plan: TagPlan) -> some View {
        let changes = plan.albumChanges.filter { showUnchanged || $0.kind != .unchanged }
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Album fields").font(.caption).bold().foregroundStyle(.secondary)
                Spacer()
                Toggle("Show unchanged", isOn: $showUnchanged).toggleStyle(.checkbox).font(.caption)
            }
            if changes.isEmpty {
                Text(showUnchanged ? "No album-level fields" : "No album-level changes").font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(changes) { change in
                TagChangeRow(change: change, locked: record.tagLocks.contains(change.name)) {
                    tagging.toggleLock(change.name, for: record, members: members)
                }
            }
        }
    }

    private func tracksSection(_ plan: TagPlan) -> some View {
        DisclosureGroup(isExpanded: $showTracks) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(plan.tracks) { track in
                    let changes = plan.trackOnlyChanges(track).filter { showUnchanged || $0.kind != .unchanged }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(track.url.lastPathComponent).font(.caption).bold().lineLimit(1).truncationMode(.middle)
                            if !track.existingPictures.isEmpty {
                                Text("· \(track.existingPictures.count) picture(s)").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        if changes.isEmpty {
                            Text("No track-specific changes").font(.caption).foregroundStyle(.tertiary)
                        }
                        ForEach(changes) { change in
                            TagChangeRow(change: change, locked: record.tagLocks.contains(change.name)) {
                                tagging.toggleLock(change.name, for: record, members: members)
                            }
                        }
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            Text("Tracks (\(plan.tracks.count))").font(.caption).bold().foregroundStyle(.secondary)
        }
    }
}

struct TagChangeRow: View {
    let change: TagChange
    let locked: Bool
    let onToggleLock: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onToggleLock) {
                Image(systemName: locked ? "lock.fill" : "lock.open")
                    .foregroundStyle(locked ? Color.accentColor : Color.secondary.opacity(0.4))
            }
            .buttonStyle(.borderless)
            .help(locked ? "Locked: the file keeps its value" : "Lock this field to keep the file's value")
            Text(change.name).font(.caption).monospaced().frame(width: 190, alignment: .leading).lineLimit(1)
            VStack(alignment: .leading, spacing: 1) {
                switch change.kind {
                case .unchanged:
                    Text(change.new.joined(separator: "; ")).font(.caption).foregroundStyle(.secondary)
                case .added:
                    Text(change.new.joined(separator: "; ")).font(.caption).foregroundStyle(.green)
                case .removed:
                    Text(change.old.joined(separator: "; ")).font(.caption).strikethrough().foregroundStyle(.red)
                case .changed:
                    Text(change.old.joined(separator: "; ")).font(.caption).strikethrough().foregroundStyle(.secondary)
                    Text(change.new.joined(separator: "; ")).font(.caption).foregroundStyle(.orange)
                }
            }
            .textSelection(.enabled)
            Spacer()
        }
        .opacity(locked && change.kind != .unchanged ? 0.6 : 1)
    }
}
