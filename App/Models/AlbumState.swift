import Foundation

// Lifecycle of an album in the queue. Stored as its raw value in SwiftData.
//   pending → scanning → scanned → identifying → confident | needsReview
//   → applying → done, with `error` reachable from any step.
enum AlbumState: String, Codable, Sendable, CaseIterable {
    case pending
    case scanning
    case scanned
    case identifying
    case confident
    case needsReview
    case applying
    case done
    case error

    var label: String {
        switch self {
        case .pending: return String(localized: "Pending")
        case .scanning: return String(localized: "Scanning")
        case .scanned: return String(localized: "Ready to identify")
        case .identifying: return String(localized: "Identifying")
        case .confident: return String(localized: "Confident match")
        case .needsReview: return String(localized: "Needs review")
        case .applying: return String(localized: "Applying")
        case .done: return String(localized: "Done")
        case .error: return String(localized: "Error")
        }
    }

    var systemImage: String {
        switch self {
        case .pending: return "clock"
        case .scanning: return "magnifyingglass"
        case .scanned: return "doc.text.magnifyingglass"
        case .identifying: return "waveform.badge.magnifyingglass"
        case .confident: return "checkmark.seal"
        case .needsReview: return "questionmark.circle"
        case .applying: return "pencil.and.outline"
        case .done: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle"
        }
    }
}
