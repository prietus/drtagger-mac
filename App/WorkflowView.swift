import AppKit
import IdentifyKit
import LibraryKit
import SACDKit
import SplitKit
import SwiftUI

// Shared actions of the album workflow: where files go, and producing the
// per-track files (SACD extraction, CUE image split) with the settings.
@MainActor
enum Workflow {

    // The library root, asking once when it is not set.
    static func destination(_ settings: AppSettings, message: String) -> URL? {
        if let root = settings.libraryRootURL { return root }
        guard let picked = FolderPicker.pickFolder(message: message) else { return nil }
        settings.libraryRoot = picked.path
        return picked
    }

    // Records whose tags need files that do not exist yet.
    static func needsFiles(_ r: AlbumRecord) -> Bool {
        switch r.kind {
        case .sacdISO: return r.sacdOutcomes.isEmpty
        case .cueImage: return r.splitOutcomes.isEmpty
        case .cueMultiFile, .trackFolder: return false
        }
    }

    static func splitOptions(_ settings: AppSettings, overwrite: Bool) -> SplitOptions {
        var o = SplitOptions()
        o.overwriteExisting = overwrite
        o.albumFolderTemplate = settings.albumFolderTemplate
        o.trackFileTemplate = settings.trackFileTemplate
        o.asciiFileNames = settings.asciiFileNames
        return o
    }

    static func extractOptions(_ settings: AppSettings, overwrite: Bool) -> SACDExtractOptions {
        var o = SACDExtractOptions()
        o.overwriteExisting = overwrite
        o.pausePolicy = settings.sacdPausePolicy
        o.albumFolderTemplate = settings.albumFolderTemplate
        o.trackFileTemplate = settings.trackFileTemplate
        o.asciiFileNames = settings.asciiFileNames
        return o
    }

    // Extracts or splits every member that still needs files. False when
    // the user cancelled the folder choice or a member ended in error.
    static func produceFiles(_ members: [AlbumRecord], disc: DiscService, settings: AppSettings) async -> Bool {
        let pending = members.filter(needsFiles)
        guard !pending.isEmpty else { return true }
        guard let root = destination(settings, message: String(localized: "Choose the library folder where the tracks are written.")) else { return false }
        for m in pending {
            if m.kind == .sacdISO {
                await disc.extractSACD(m, into: root, multichannel: settings.extractMultichannel, options: extractOptions(settings, overwrite: false), trashOriginals: settings.moveOriginalsToTrash)
            } else {
                await disc.split(m, into: root, locator: settings.ffmpegLocator, options: splitOptions(settings, overwrite: false), trashOriginals: settings.moveOriginalsToTrash)
            }
            if m.state == .error || needsFiles(m) { return false }
        }
        return true
    }
}

// Top of the inspector: the five steps of an album, what is happening now,
// and one button for the next thing to do.
struct WorkflowView: View {
    let record: AlbumRecord
    @Environment(LibraryController.self) private var library
    @Environment(IdentifyService.self) private var identify
    @Environment(DiscService.self) private var disc
    @Environment(TagService.self) private var tagging
    @Environment(AppSettings.self) private var settings
    @State private var running = false

    private var members: [AlbumRecord] { library.members(of: record) }
    private var identified: Bool { record.identification != nil }
    private var chosen: Bool { TagService.chosenCandidate(record) != nil }
    private var isConfident: Bool { record.identification?.isConfident == true && record.selectedCandidateID == record.identification?.best?.id }
    private var filesNeeded: Bool { members.contains(where: Workflow.needsFiles) }
    private var plan: TagPlan? { tagging.plan(for: record) }
    private var applied: Bool { record.taggedAt != nil && plan == nil }
    private var busy: Bool {
        running || identify.isBusy(record) || tagging.isBusy(record) || members.contains { disc.isBusy($0) }
    }

    enum StepState { case done, current, pending }

    private var filesLabel: String {
        switch record.kind {
        case .sacdISO: return String(localized: "Extract")
        case .cueImage: return String(localized: "Split")
        default: return String(localized: "Files")
        }
    }

    private var steps: [(String, StepState)] {
        let s1: StepState = identified ? .done : .current
        let s2: StepState = chosen ? .done : (identified ? .current : .pending)
        let s3: StepState = !filesNeeded ? .done : (chosen ? .current : .pending)
        let s4: StepState = (plan != nil || applied) ? .done : (chosen && !filesNeeded ? .current : .pending)
        let s5: StepState = applied ? .done : (plan != nil ? .current : .pending)
        return [(String(localized: "Identify"), s1), (String(localized: "Release"), s2), (filesLabel, s3), (String(localized: "Tags"), s4), (String(localized: "Apply"), s5)]
    }

    // What is running now, from whichever service owns it.
    private var activity: (message: String, fraction: Double?)? {
        if let a = identify.activity(for: record) { return (a.message, a.fraction) }
        for m in members { if let a = disc.activity(for: m) { return (members.count > 1 ? String(localized: "Disc \(m.discPosition): ") + a.message : a.message, a.fraction) } }
        if let a = tagging.activity(for: record) { return (a.message, a.fraction) }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepBar
            HStack(alignment: .center, spacing: 12) {
                status
                Spacer(minLength: 8)
                // A SACD image cannot be fingerprinted until it is extracted:
                // when the first pass is not sure, extract and try again.
                if !busy, identified, !isConfident, !applied, record.kind == .sacdISO, filesNeeded {
                    Button("Extract & Identify Again") {
                        Task {
                            running = true
                            defer { running = false }
                            if await Workflow.produceFiles(members, disc: disc, settings: settings) {
                                await identify.identify(record, members: members, settings: settings)
                            }
                        }
                    }
                    .help("Acoustic fingerprints need the extracted DSF files")
                }
                if !busy, chosen, isConfident, !applied, plan == nil {
                    Button("Process All") { Task { await processAll() } }
                        .help("Extract or split, write tags, cover and ReplayGain, and file the album in the library")
                }
                primaryButton
            }
            if let activity {
                HStack(spacing: 8) {
                    if let f = activity.fraction { ProgressView(value: f).frame(maxWidth: 260) } else { ProgressView().controlSize(.small) }
                    Text(activity.message).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        // Files just appeared: show what will be written without another click.
        .onChange(of: record.sacdOutcomeData) { _, _ in autoPreview() }
        .onChange(of: record.splitOutcomeData) { _, _ in autoPreview() }
        .onChange(of: record.selectedCandidateID) { _, _ in autoPreview() }
    }

    private var stepBar: some View {
        HStack(spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                if i > 0 {
                    Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 1).frame(maxWidth: 28)
                }
                HStack(spacing: 4) {
                    Image(systemName: step.1 == .done ? "checkmark.circle.fill" : step.1 == .current ? "circle.inset.filled" : "circle")
                        .foregroundStyle(step.1 == .done ? Color.green : step.1 == .current ? Color.accentColor : Color.secondary)
                    Text(step.0)
                        .fontWeight(step.1 == .current ? .semibold : .regular)
                        .foregroundStyle(step.1 == .pending ? .secondary : .primary)
                }
                .font(.callout)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if !identified {
            Text("Find the exact release from tags, disc data, scans and fingerprints.").foregroundStyle(.secondary)
        } else if !chosen {
            Label("Choose a release in Identification below.", systemImage: "hand.point.down").foregroundStyle(.orange)
        } else if let c = TagService.chosenCandidate(record) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(c.artist) – \(c.title)").bold().lineLimit(1)
                Text([c.year, c.country, c.mediaFormat, c.catalogNumber].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        if !identified {
            Button(identify.isBusy(record) ? "Identifying…" : "Identify") {
                Task { await identify.identify(record, members: members, settings: settings) }
            }
            .buttonStyle(.borderedProminent).disabled(busy)
        } else if !chosen {
            EmptyView()
        } else if filesNeeded {
            Button(record.kind == .sacdISO ? "Extract & Preview Tags" : "Split & Preview Tags") {
                Task {
                    running = true
                    defer { running = false }
                    if await Workflow.produceFiles(members, disc: disc, settings: settings) {
                        await tagging.buildPlan(record, members: members, settings: settings)
                    }
                }
            }
            .buttonStyle(.borderedProminent).disabled(busy)
        } else if let plan {
            Button("Apply") { Task { await tagging.apply(record, members: members, settings: settings) } }
                .buttonStyle(.borderedProminent)
                .disabled(busy || !plan.hasWork)
                .help("Write the tags and the cover; originals are backed up and the audio is verified untouched")
        } else if applied {
            HStack(spacing: 8) {
                Label("Done", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                if let first = record.tagReports.first {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: first.path)]) }
                }
            }
        } else {
            Button("Preview Tags") { Task { await tagging.buildPlan(record, members: members, settings: settings) } }
                .buttonStyle(.borderedProminent).disabled(busy)
        }
    }

    private func autoPreview() {
        guard !running, chosen, !filesNeeded, plan == nil, !applied, !busy else { return }
        Task { await tagging.buildPlan(record, members: members, settings: settings) }
    }

    // Confident match: files, tags, cover, ReplayGain and library layout in one go.
    private func processAll() async {
        running = true
        defer { running = false }
        guard await Workflow.produceFiles(members, disc: disc, settings: settings) else { return }
        await tagging.buildPlan(record, members: members, settings: settings)
        guard let plan = tagging.plan(for: record), plan.hasWork else { return }
        await tagging.apply(record, members: members, settings: settings)
    }
}
