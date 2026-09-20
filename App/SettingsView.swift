import SACDKit
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
                Text("The front cover is embedded resized to this longest side. Full-resolution scans are kept as files next to the tracks.")
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
                Link("Register an application at acoustid.org", destination: URL(string: "https://acoustid.org/new-application")!)
                    .font(.caption)
            }
            Section("Discogs (credits, editions, catalog numbers)") {
                SecureField("Personal access token", text: $settings.discogsToken)
                Link("Generate a token in your Discogs developer settings", destination: URL(string: "https://www.discogs.com/settings/developers")!)
                    .font(.caption)
            }
            Section("fanart.tv (high-resolution artwork)") {
                SecureField("Project API key", text: $settings.fanartKey)
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
