import Foundation

// One field before and after a merge, for the preview.
public struct TagChange: Sendable, Equatable, Hashable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        case added, removed, changed, unchanged
    }

    public let name: String
    public let old: [String]
    public let new: [String]

    public var id: String { name }
    public var kind: Kind {
        if old.isEmpty && !new.isEmpty { return .added }
        if !old.isEmpty && new.isEmpty { return .removed }
        return old == new ? .unchanged : .changed
    }
}

// Overwrite policy from DESIGN.md: fields the candidate provides replace
// the existing ones; identity fields it does not provide are cleared
// (they described another release); everything else is preserved; locked
// fields never change.
public enum TagMerge {

    public static func merge(existing: TagSet, proposed: TagSet, locked: Set<String> = []) -> (result: TagSet, changes: [TagChange]) {
        var result = existing
        let lockedUpper = Set(locked.map { $0.uppercased() })
        for name in proposed.names where !lockedUpper.contains(name) {
            result[name] = proposed[name]
        }
        if !proposed.isEmpty {
            for name in TagField.identityFields where proposed[name].isEmpty && !lockedUpper.contains(name) {
                result.remove(name)
            }
        }
        let allNames = orderedUnion(existing.names, result.names)
        let changes = allNames.map { TagChange(name: $0, old: existing[$0], new: result[$0]) }
        return (result, changes)
    }

    private static func orderedUnion(_ a: [String], _ b: [String]) -> [String] {
        var seen = Set<String>()
        let union = (a + b).filter { seen.insert($0).inserted }
        let known = TagField.canonicalOrder.filter { seen.contains($0) }
        return known + union.filter { !TagField.canonicalOrder.contains($0) }.sorted()
    }
}
