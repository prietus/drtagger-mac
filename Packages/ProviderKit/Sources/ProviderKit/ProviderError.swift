import Foundation

// Transport-level failures shared by every provider client. Provider-specific
// errors (AcoustID service messages, Discogs auth) stay on their own clients.
public enum ProviderError: LocalizedError, Equatable, Sendable {
    case invalidURL
    case httpError(Int)
    case rateLimited(retryAfterSeconds: Int?)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Could not build a valid request URL."
        case .httpError(let code): return "The service returned HTTP \(code)."
        case .rateLimited(let secs):
            if let secs { return "Rate limited by the service; retry in \(secs) s." }
            return "Rate limited by the service."
        }
    }
}
