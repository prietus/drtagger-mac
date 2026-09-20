import Foundation
import Observation

// User-visible configuration that survives launches. Plain values live in
// UserDefaults; provider credentials live in the Keychain. The app ships
// with no API keys at all: every provider that needs one is configured by
// the user in Settings > Providers.
@Observable
@MainActor
final class AppSettings {

    enum KeychainAccount {
        static let acoustIDKey = "acoustid.apikey"
        static let discogsToken = "discogs.token"
        static let fanartKey = "fanart.apikey"
    }

    private enum Key {
        static let libraryRoot = "library.root"
        static let ffmpegOverride = "ffmpeg.overridePath"
        static let embedCoverMaxPixels = "artwork.embedMaxPixels"
        static let moveOriginalsToTrash = "split.moveOriginalsToTrash"
        static let extractMultichannel = "sacd.extractMultichannel"
    }

    // Destination library root for split tracks. Empty = not configured.
    var libraryRoot: String {
        didSet { defaults.set(libraryRoot, forKey: Key.libraryRoot) }
    }
    // Optional path to a system ffmpeg used instead of the embedded one.
    var ffmpegOverridePath: String {
        didSet { defaults.set(ffmpegOverridePath, forKey: Key.ffmpegOverride) }
    }
    // Longest side of the embedded front cover, in pixels.
    var embedCoverMaxPixels: Int {
        didSet { defaults.set(embedCoverMaxPixels, forKey: Key.embedCoverMaxPixels) }
    }
    var moveOriginalsToTrash: Bool {
        didSet { defaults.set(moveOriginalsToTrash, forKey: Key.moveOriginalsToTrash) }
    }
    var extractMultichannel: Bool {
        didSet { defaults.set(extractMultichannel, forKey: Key.extractMultichannel) }
    }

    var acoustIDKey: String {
        didSet { Self.store(acoustIDKey, account: KeychainAccount.acoustIDKey) }
    }
    var discogsToken: String {
        didSet { Self.store(discogsToken, account: KeychainAccount.discogsToken) }
    }
    var fanartKey: String {
        didSet { Self.store(fanartKey, account: KeychainAccount.fanartKey) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        libraryRoot = defaults.string(forKey: Key.libraryRoot) ?? ""
        ffmpegOverridePath = defaults.string(forKey: Key.ffmpegOverride) ?? ""
        let px = defaults.integer(forKey: Key.embedCoverMaxPixels)
        embedCoverMaxPixels = px > 0 ? px : 1500
        moveOriginalsToTrash = defaults.bool(forKey: Key.moveOriginalsToTrash)
        extractMultichannel = defaults.bool(forKey: Key.extractMultichannel)
        acoustIDKey = Keychain.get(KeychainAccount.acoustIDKey) ?? ""
        discogsToken = Keychain.get(KeychainAccount.discogsToken) ?? ""
        fanartKey = Keychain.get(KeychainAccount.fanartKey) ?? ""
    }

    var libraryRootURL: URL? {
        libraryRoot.isEmpty ? nil : URL(fileURLWithPath: libraryRoot, isDirectory: true)
    }

    var isAcoustIDConfigured: Bool { !acoustIDKey.trimmed.isEmpty }
    var isDiscogsConfigured: Bool { !discogsToken.trimmed.isEmpty }
    var isFanartConfigured: Bool { !fanartKey.trimmed.isEmpty }

    var ffmpegLocator: FFmpegLocator {
        FFmpegLocator(overridePath: ffmpegOverridePath.trimmed)
    }

    // Empty values delete the Keychain item instead of storing "".
    private static func store(_ value: String, account: String) {
        let v = value.trimmed
        if v.isEmpty {
            Keychain.delete(account)
        } else {
            try? Keychain.set(v, for: account)
        }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
