import SACDKit
import ProviderKit
import SplitKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            ProvidersSettingsView()
                .tabItem { Label("Providers", systemImage: "key") }
            AdvancedSettingsView()
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 560)
        .padding(.bottom, 8)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @Environment(AppSettings.self) private var settings

    private var templatePreview: String {
        let sample = ["albumartist": "Miles Davis", "album": "Kind of Blue", "year": "1997", "originalyear": "1959", "artist": "Miles Davis",
                      "title": "So What", "track": "01", "tracktotal": "5", "disc": "1", "disctotal": "1", "label": "Columbia", "catalognumber": "CK 64935", "media": "CD"]
        let folder = PathTemplate.render(settings.albumFolderTemplate, values: sample, ascii: settings.asciiFileNames)
        let file = PathTemplate.render(settings.trackFileTemplate, values: sample, ascii: settings.asciiFileNames)
        return (folder.isEmpty ? "?" : folder) + "/" + (file.isEmpty ? "?" : file) + ".flac"
    }

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Library") {
                LabeledContent("Destination folder") {
                    HStack {
                        Text(settings.libraryRoot.isEmpty ? String(localized: "Not set") : settings.libraryRoot)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(settings.libraryRoot.isEmpty ? .secondary : .primary)
                        Spacer()
                        Button("Choose…") {
                            if let url = FolderPicker.pickFolder(message: String(localized: "Choose the library folder where split tracks are written.")) {
                                settings.libraryRoot = url.path
                            }
                        }
                    }
                }
                Toggle("Move original images to the Trash after a verified split", isOn: $settings.moveOriginalsToTrash)
                TextField("Album folder", text: $settings.albumFolderTemplate)
                TextField("Track file", text: $settings.trackFileTemplate)
                Text(templatePreview)
                    .font(.caption)
                    .monospaced()
                    .foregroundStyle(.secondary)
                Text("Placeholders: " + PathTemplate.placeholders.map { "{\($0)}" }.joined(separator: " ") + ". Multi-disc releases get a \"Disc N\" folder automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("ASCII-only file names (transliterate accents and other scripts)", isOn: $settings.asciiFileNames)
                Toggle("Move files into the library layout after Apply", isOn: $settings.organizeAfterApply)
            }
            Section("Queue") {
                Toggle("Remember the queue between launches", isOn: $settings.keepQueueBetweenLaunches)
                Text("Off: the app starts with an empty queue every time. On: albums and their identification results stay until you remove them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("SACD") {
                Toggle("Also extract the multichannel area when present", isOn: $settings.extractMultichannel)
                Picker("Audio between tracks", selection: $settings.sacdPausePolicy) {
                    Text("Keep at the end of the previous track").tag(SACDExtractOptions.PausePolicy.appendToPrevious)
                    Text("Drop (sacd_extract behaviour)").tag(SACDExtractOptions.PausePolicy.drop)
                }
            }
            Section("Artwork") {
                Picker("Embedded cover size", selection: $settings.embedCoverMaxPixels) {
                    Text("1000 px").tag(1000)
                    Text("1500 px").tag(1500)
                    Text("2000 px").tag(2000)
                    Text("3000 px").tag(3000)
                }
                Toggle("Embed the front cover in every track", isOn: $settings.embedFrontCover)
                Toggle("Save the full-resolution cover as a file next to the tracks", isOn: $settings.saveCoverFile)
                Text("The front cover is embedded resized to this longest side. An existing cover file in the folder is never replaced.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Tags") {
                Toggle("Measure loudness and write ReplayGain / R128 tags on Apply", isOn: $settings.computeReplayGain)
                Toggle("Write GENRE and STYLE from Discogs", isOn: $settings.writeGenresFromDiscogs)
                Text("Fields taken from the chosen release replace the existing ones; everything else in the files (ReplayGain, comments, custom tags) is preserved. Individual fields can be locked in the preview.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Providers

struct ProvidersSettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Text("drtagger ships without API keys. MusicBrainz, Cover Art Archive, iTunes Search and Deezer need none; the providers below require a key you create with your own account. Keys are stored in your Keychain.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("AcoustID (acoustic fingerprints)") {
                SecureField("Application API key", text: $settings.acoustIDKey)
                KeyTestRow(enabled: settings.isAcoustIDConfigured) {
                    await AcoustIDClient(clientKey: settings.acoustIDKey.trimmed, userAgent: IdentifyService.userAgent).validateKey()
                }
                Link("Register an application at acoustid.org", destination: URL(string: "https://acoustid.org/new-application")!)
                    .font(.caption)
            }
            Section("Discogs (credits, editions, catalog numbers)") {
                SecureField("Personal access token", text: $settings.discogsToken)
                KeyTestRow(enabled: settings.isDiscogsConfigured) {
                    await DiscogsClient(userAgent: IdentifyService.userAgent, token: settings.discogsToken.trimmed).validateToken()
                }
                Text("Use the personal access token from \"Generate new token\" on the developer page, not an application's Consumer Key or Consumer Secret (those are for OAuth apps).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("Open your Discogs developer settings", destination: URL(string: "https://www.discogs.com/settings/developers")!)
                    .font(.caption)
            }
            Section("fanart.tv (high-resolution artwork)") {
                SecureField("Project API key", text: $settings.fanartKey)
                KeyTestRow(enabled: settings.isFanartConfigured) {
                    await FanartClient(apiKey: settings.fanartKey.trimmed, userAgent: IdentifyService.userAgent).validateKey()
                }
                Link("Request an API key at fanart.tv", destination: URL(string: "https://fanart.tv/get-an-api-key/")!)
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Advanced

struct AdvancedSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var info: FFmpegLocator.Info?
    @State private var errorText: String?
    @State private var checking = false

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("ffmpeg") {
                LabeledContent("Status") {
                    if checking {
                        ProgressView().controlSize(.small)
                    } else if let info {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(info.versionLine)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(statusDetail(info))
                                .font(.caption)
                                .foregroundStyle(info.isGPL ? .orange : .secondary)
                        }
                    } else if let errorText {
                        Text(errorText)
                            .foregroundStyle(.red)
                            .font(.caption)
                    } else {
                        Text("Unknown")
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Override path") {
                    HStack {
                        TextField("Leave empty to use the embedded ffmpeg", text: $settings.ffmpegOverridePath)
                            .textFieldStyle(.roundedBorder)
                        Button("Choose…") {
                            if let url = FolderPicker.pickFile(message: String(localized: "Choose an ffmpeg executable.")) {
                                settings.ffmpegOverridePath = url.path
                            }
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("Check") { check() }
                        .disabled(checking)
                }
                Text("The embedded ffmpeg is a minimal LGPL build. A Homebrew ffmpeg works for development but is GPL and must not be redistributed with the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { check() }
        .onChange(of: settings.ffmpegOverridePath) { _, _ in check() }
    }

    private func statusDetail(_ info: FFmpegLocator.Info) -> String {
        var parts: [String] = []
        switch info.location.source {
        case .bundled: parts.append(String(localized: "embedded"))
        case .override: parts.append(String(localized: "override"))
        case .system: parts.append(String(localized: "system"))
        }
        parts.append(info.location.ffmpeg.path)
        if info.isGPL { parts.append(String(localized: "GPL build, development only")) }
        return parts.joined(separator: " · ")
    }

    private func check() {
        let locator = settings.ffmpegLocator
        checking = true
        errorText = nil
        Task {
            do {
                let result = try await locator.inspect()
                info = result
            } catch {
                info = nil
                errorText = error.localizedDescription
            }
            checking = false
        }
    }
}

// MARK: - Panels

@MainActor
enum FolderPicker {
    static func pickFolder(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func pickFile(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }
}

#Preview {
    SettingsView()
        .environment(AppSettings())
}

// "Test" button next to a key field: asks the service whether it accepts
// the key and shows the answer in place.
struct KeyTestRow: View {
    let enabled: Bool
    let check: @Sendable () async -> KeyCheck
    @State private var busy = false
    @State private var result: KeyCheck?

    var body: some View {
        HStack(spacing: 8) {
            Button("Test") {
                busy = true
                result = nil
                Task {
                    let r = await check()
                    await MainActor.run { result = r; busy = false }
                }
            }
            .disabled(!enabled || busy)
            if busy { ProgressView().controlSize(.small) }
            if let result {
                switch result {
                case .valid(let m): Label(m, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .invalid(let m): Label(m, systemImage: "xmark.circle.fill").foregroundStyle(.red)
                case .unreachable(let m): Label(m, systemImage: "wifi.exclamationmark").foregroundStyle(.orange)
                }
            } else if !enabled {
                Text("Enter a key to test it").foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
    }
}
