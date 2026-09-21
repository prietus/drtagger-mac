import IdentifyKit
import ProviderKit
import SwiftUI

// Inspector section: identification signals, the ranked candidates and
// the user's pick.
struct IdentificationView: View {
    let record: AlbumRecord
    @Environment(IdentifyService.self) private var identify
    @Environment(AppSettings.self) private var settings
    @State private var showLog = false
    @State private var onlyPlausibleFormats: Bool? = nil   // nil: default for the album kind
    @State private var showOtherFormats = false

    // Fold away impossible media by default only when the source is certain:
    // a Scarletbook image can only come from a SACD.
    private var foldOtherFormats: Bool { onlyPlausibleFormats ?? (record.kind == .sacdISO) }

    var body: some View {
        GroupBox("Identification") {
            VStack(alignment: .leading, spacing: 10) {
                header
                if let activity = identify.activity(for: record) {
                    HStack(spacing: 8) {
                        ProgressView(value: activity.fraction).frame(width: 160)
                        Text(activity.message).font(.callout).foregroundStyle(.secondary)
                    }
                }
                if let error = identify.error(for: record) {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
                }
                if let result = record.identification {
                    signalsSummary(result)
                    if result.candidates.isEmpty {
                        Text("No release matched. Add API keys in Settings or check the folder's artwork and tags.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        candidateList(result)
                    }
                    DisclosureGroup("Log (\(result.log.count) lines)", isExpanded: $showLog) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(result.log.enumerated()), id: \.offset) { _, line in
                                Text(line).font(.caption).monospaced().textSelection(.enabled)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let result = record.identification, let best = result.best {
                if result.isConfident {
                    Label("Confident match", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                } else if best.confidence >= .likely {
                    Label("Likely match, please review", systemImage: "questionmark.circle").foregroundStyle(.orange)
                } else {
                    Label("\(result.candidates.count) candidates, none certain", systemImage: "questionmark.circle").foregroundStyle(.orange)
                }
                Text("· \(String(format: "%.0f", result.elapsedSeconds)) s").foregroundStyle(.tertiary)
            } else if record.identification != nil {
                Label("No candidates", systemImage: "xmark.circle").foregroundStyle(.secondary)
            } else {
                Text("Not identified yet").foregroundStyle(.tertiary)
            }
            Spacer()
            if !settings.isAcoustIDConfigured && record.identification?.fingerprints == nil {
                Text("No AcoustID key: fingerprints off")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if let result = record.identification, result.candidates.contains(where: { $0.formatCompatibility == .unlikely }) {
                Toggle("Plausible formats only", isOn: Binding(get: { foldOtherFormats }, set: { onlyPlausibleFormats = $0 }))
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .help("Fold away releases whose medium cannot be the source of these files")
            }
            Button(record.identification == nil ? "Identify" : "Identify Again") {
                Task { await identify.identify(record, settings: settings) }
            }
            .disabled(identify.isBusy(record))
        }
        .font(.callout)
    }

    private func signalsSummary(_ result: IdentificationResult) -> some View {
        let s = result.signals
        var parts: [String] = []
        if !s.uniqueBarcodes.isEmpty { parts.append("barcode " + s.uniqueBarcodes.joined(separator: ", ")) }
        if !s.uniqueCatalogNumbers.isEmpty { parts.append("catalog " + s.uniqueCatalogNumbers.prefix(3).joined(separator: ", ")) }
        if s.discID != nil { parts.append("disc ID") }
        if !s.uniqueReleaseIDs.isEmpty { parts.append("\(s.uniqueReleaseIDs.count) MBID") }
        if let fp = result.fingerprints, fp.fingerprintedTracks > 0 { parts.append("fingerprints \(fp.tracksWithHits)/\(fp.fingerprintedTracks)") }
        if let e = s.editionHint { parts.append("edition \(e)") }
        if let c = s.countryHint { parts.append("country \(c)") }
        if let src = s.sourceHint { parts.append("source \(src.rawValue)") }
        if !s.artworkScans.isEmpty { parts.append("\(s.artworkScans.count) scans read") }
        return Text(parts.isEmpty ? String(localized: "No identifying signals found") : "Signals: " + parts.joined(separator: " · "))
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func candidateList(_ result: IdentificationResult) -> some View {
        let folded = foldOtherFormats ? result.candidates.filter { $0.formatCompatibility == .unlikely } : []
        var shown = foldOtherFormats ? result.candidates.filter { $0.formatCompatibility != .unlikely } : result.candidates
        // Never leave the list empty because of the filter.
        let filterEmptied = shown.isEmpty && !folded.isEmpty
        if filterEmptied { shown = result.candidates }
        return VStack(alignment: .leading, spacing: 4) {
            if filterEmptied {
                Text("No release in a matching format; showing every format.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(shown.prefix(12)) { scored in
                CandidateRow(scored: scored, selected: record.selectedCandidateID == scored.id) {
                    identify.select(record.selectedCandidateID == scored.id ? nil : scored, for: record)
                }
            }
            if shown.count > 12 {
                Text("\(shown.count - 12) more candidates not shown")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if !filterEmptied, !folded.isEmpty {
                DisclosureGroup("\(folded.count) in other formats", isExpanded: $showOtherFormats) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(folded.prefix(12)) { scored in
                            CandidateRow(scored: scored, selected: record.selectedCandidateID == scored.id) {
                                identify.select(record.selectedCandidateID == scored.id ? nil : scored, for: record)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.caption)
            }
        }
    }
}

struct CandidateRow: View {
    let scored: ScoredCandidate
    let selected: Bool
    let onSelect: () -> Void
    @State private var expanded = false

    private var c: Candidate { scored.candidate }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 8) {
                Button(action: onSelect) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                }
                .buttonStyle(.borderless)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("\(c.artist) – \(c.title)").bold().lineLimit(1)
                        confidenceBadge
                        Text(String(format: "%.0f", scored.score)).font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                    }
                    Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    if expanded {
                        ForEach(scored.reasons, id: \.self) { r in
                            Text("• " + r).font(.caption).foregroundStyle(.secondary)
                        }
                        Text("MBID \(c.providerID)").font(.caption2).monospaced().foregroundStyle(.tertiary).textSelection(.enabled)
                    }
                }
                Spacer()
                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
        .padding(6)
        .background(selected ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    }

    private var details: String {
        var parts: [String] = []
        if let y = c.year { parts.append(y) }
        if let co = c.country { parts.append(co) }
        if let f = c.mediaFormat { parts.append(f) }
        if let l = c.label { parts.append(l) }
        if let cat = c.catalogNumber { parts.append(cat) }
        if let b = c.barcode { parts.append(b) }
        if let n = c.trackCount { parts.append("\(n) tracks") }
        if let d = c.disambiguation, !d.isEmpty { parts.append(d) }
        if scored.formatCompatibility == .unlikely { parts.append("format unlikely for these files") }
        return parts.joined(separator: " · ")
    }

    private var confidenceBadge: some View {
        let (text, color): (String, Color) = {
            switch scored.confidence {
            case .confident: return ("confident", .green)
            case .likely: return ("likely", .orange)
            case .possible: return ("possible", .secondary)
            case .unlikely: return ("unlikely", .secondary)
            }
        }()
        return Text(text)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}
