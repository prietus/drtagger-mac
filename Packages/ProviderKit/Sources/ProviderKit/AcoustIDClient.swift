import Foundation

// AcoustID lookup client.
//
// API docs: https://acoustid.org/webservice
// Endpoint: GET https://api.acoustid.org/v2/lookup
// Rate limit: 3 req/s per client key. We don't rate-limit explicitly
// because a single album load only fingerprints one track and hits
// this endpoint once; the MusicBrainz follow-up dominates overall
// latency.
//
// The client key is per-application, not per-user. Register at
// https://acoustid.org/api-key if you need to rotate it.
//
// Response shape (meta=recordings+releases):
// { "status": "ok", "results": [
//     { "id": "...", "score": 0.98, "recordings": [
//         { "id": "<mb-recording-uuid>", "title": "...", "duration": 300,
//           "artists": [...],
//           "releases": [
//             { "id": "<mb-release-uuid>", "title": "...", ... }
//           ]
//         }
//     ] }
// ] }

public actor AcoustIDClient {

    public struct Match: Sendable, Equatable {
        public let score: Double                // 0.0 – 1.0
        public let recordingID: String          // MBID of the recording
        public let recordingTitle: String?
        public let releaseIDs: [String]         // MBIDs of releases containing this recording

        public init(
            score: Double,
            recordingID: String,
            recordingTitle: String?,
            releaseIDs: [String]
        ) {
            self.score = score
            self.recordingID = recordingID
            self.recordingTitle = recordingTitle
            self.releaseIDs = releaseIDs
        }
    }

    public enum AcoustIDError: LocalizedError {
        case invalidResponse
        case serviceError(String)

        public var errorDescription: String? {
            switch self {
            case .invalidResponse: return "AcoustID returned an unexpected response."
            case .serviceError(let s): return "AcoustID service error: \(s)"
            }
        }
    }

    public let clientKey: String
    public let userAgent: String
    private let session: URLSession
    private let baseURL = URL(string: "https://api.acoustid.org/v2/lookup")!

    public init(clientKey: String, userAgent: String, session: URLSession = .shared) {
        self.clientKey = clientKey
        self.userAgent = userAgent
        self.session = session
    }

    public nonisolated var isConfigured: Bool { !clientKey.isEmpty }

    // One lookup returns 0..n matches ordered by score descending. We
    // flatten nested recording → release pairs into a single list of
    // release MBIDs per match so callers can just loop and ask
    // MusicBrainzClient.releaseDetail for each.
    //
    // The request is sent as POST with a form-encoded body. AcoustID
    // explicitly recommends POST for fingerprint uploads because the
    // base64 payload regularly exceeds the URL length limits enforced
    // by some proxies and by AcoustID's own frontend — a naive GET
    // returns HTTP 400 for anything but the shortest fingerprints.
    public func lookup(fingerprint: String, durationSeconds: Int) async throws -> [Match] {
        guard !fingerprint.isEmpty else { return [] }

        // Manual form encoding instead of URLComponents.percentEncoded
        // so we control exactly which characters get escaped. AcoustID
        // is permissive about the base64url variant chromaprint emits
        // (uses `_` and `-`), but any stray `+` in a future encoding
        // change would silently be treated as a space.
        // Build the form body manually. The meta value uses spaces as
        // separators (AcoustID convention); in form encoding a `+` IS a
        // space, so we leave `+` in the allowed set — chromaprint's
        // base64url fingerprints never contain `+` anyway.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=?")
        let params: [(String, String)] = [
            ("client", clientKey),
            ("meta", "recordings releaseids"),
            ("duration", String(durationSeconds)),
            ("fingerprint", fingerprint),
        ]
        let body = params
            .map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")

        var req = URLRequest(url: baseURL, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(body.utf8)
        print("[ACOUSTID] POST body size=\(body.count), fingerprint size=\(fingerprint.count)")

        let (data, resp) = try await session.data(for: req)

        // Debug: log raw response
        if let http = resp as? HTTPURLResponse {
            let preview = String(data: data.prefix(500), encoding: .utf8) ?? "<binary>"
            print("[ACOUSTID] HTTP \(http.statusCode), body size=\(data.count), preview: \(preview)")
        }

        // AcoustID returns its own structured error body on 4xx; decode
        // that first so the user-visible message is the actual service
        // reason ("invalid fingerprint", "missing parameter", etc.)
        // rather than a bare "HTTP 400".
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            if let decoded = try? JSONDecoder().decode(AcoustIDLookupResponse.self, from: data),
               let err = decoded.error {
                throw AcoustIDError.serviceError("\(err.message) (HTTP \(http.statusCode))")
            }
            throw ProviderError.httpError(http.statusCode)
        }

        let decoded = try JSONDecoder().decode(AcoustIDLookupResponse.self, from: data)
        guard decoded.status == "ok" else {
            throw AcoustIDError.serviceError(decoded.error?.message ?? decoded.status)
        }

        var matches: [Match] = []
        for result in decoded.results ?? [] {
            let score = result.score ?? 0
            for recording in result.recordings ?? [] {
                // Chromaprint sometimes matches across recordings that
                // have no MBID (community-submitted fingerprints). Drop
                // those — we need the recording ID to trace back to a
                // release we can display.
                guard let recID = recording.id, !recID.isEmpty else { continue }
                // releaseids comes from meta=releaseids (flat string array),
                // releases comes from meta=releases (array of objects).
                // Support both so the code works regardless of which meta
                // variant the server returns.
                var releaseIDs = (recording.releaseids ?? [])
                    .compactMap { $0.isEmpty ? nil : $0 }
                if releaseIDs.isEmpty {
                    releaseIDs = (recording.releases ?? [])
                        .compactMap { $0.id }
                        .filter { !$0.isEmpty }
                }
                matches.append(
                    Match(
                        score: score,
                        recordingID: recID,
                        recordingTitle: recording.title,
                        releaseIDs: releaseIDs
                    )
                )
            }
        }
        return matches
    }
}

// MARK: - Decodable wire types

private struct AcoustIDLookupResponse: Decodable {
    let status: String
    let results: [AcoustIDResult]?
    let error: AcoustIDErrorPayload?
}

private struct AcoustIDResult: Decodable {
    let id: String?
    let score: Double?
    let recordings: [AcoustIDRecording]?
}

private struct AcoustIDRecording: Decodable {
    let id: String?
    let title: String?
    let duration: Double?
    let releaseids: [String]?
    let releases: [AcoustIDRelease]?
}

private struct AcoustIDRelease: Decodable {
    let id: String?
}

private struct AcoustIDErrorPayload: Decodable {
    let message: String
}
