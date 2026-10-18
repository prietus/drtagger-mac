import Foundation
import ProviderKit

// One client per service and credential for the whole process, so the
// rate limits hold when several albums are identified at once.
final class ProviderClients: @unchecked Sendable {
    let musicBrainz: MusicBrainzClient
    let discogs: DiscogsClient?
    let acoustID: AcoustIDClient?

    private init(userAgent: String, acoustIDKey: String?, discogsToken: String?) {
        musicBrainz = MusicBrainzClient(userAgent: userAgent)
        discogs = discogsToken.flatMap { $0.isEmpty ? nil : DiscogsClient(userAgent: userAgent, token: $0) }
        acoustID = acoustIDKey.flatMap { $0.isEmpty ? nil : AcoustIDClient(clientKey: $0, userAgent: userAgent) }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: ProviderClients] = [:]

    static func shared(userAgent: String, acoustIDKey: String?, discogsToken: String?) -> ProviderClients {
        let key = [userAgent, acoustIDKey ?? "", discogsToken ?? ""].joined(separator: "\u{1}")
        lock.lock(); defer { lock.unlock() }
        if let c = cache[key] { return c }
        let c = ProviderClients(userAgent: userAgent, acoustIDKey: acoustIDKey, discogsToken: discogsToken)
        cache[key] = c
        return c
    }
}
