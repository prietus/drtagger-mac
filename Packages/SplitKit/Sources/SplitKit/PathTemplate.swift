import Foundation

// Renders "{albumartist}/{album} ({year})/{track} {title}" style templates
// into file-system-safe relative paths. Unknown tokens render empty and
// decorations left dangling by empty values ("()", " - ") are removed.
public enum PathTemplate {

    public static let defaultAlbumFolder = "{albumartist}/{album} ({year})"
    public static let defaultTrackFile = "{track} {title}"

    public static func render(_ template: String, values: [String: String]) -> String {
        // Split on the template's own slashes first so a value containing
        // "/" can never create an extra folder.
        template
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { renderComponent(String($0), values: values) }
            .filter { !$0.isEmpty }
            .joined(separator: "/")
    }

    static func renderComponent(_ template: String, values: [String: String]) -> String {
        var out = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "}") else {
                out += rest[open...]
                rest = ""
                break
            }
            let key = String(rest[rest.index(after: open)..<close]).lowercased()
            out += (values[key] ?? "").replacingOccurrences(of: "/", with: "-")
            rest = rest[rest.index(after: close)...]
        }
        out += rest
        return sanitizeComponent(out)
    }

    // One path component: no slashes or colons, no control characters, no
    // leading dots, collapsed whitespace, empty decorations dropped.
    public static func sanitizeComponent(_ s: String) -> String {
        var t = s
        t = t.replacingOccurrences(of: "/", with: "-")
        t = t.replacingOccurrences(of: ":", with: "-")
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        t = t.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined()
        for empty in ["()", "[]", "{}", "( )", "[ ]"] {
            t = t.replacingOccurrences(of: empty, with: "")
        }
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(\s-\s*)+$"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"^(\s*-\s)+"#, with: "", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespaces)
        while t.hasPrefix(".") { t.removeFirst() }
        while t.hasSuffix(".") || t.hasSuffix(" ") { t.removeLast() }
        if t.utf8.count > 200 {
            t = String(t.prefix(200)).trimmingCharacters(in: .whitespaces)
        }
        return t
    }
}
