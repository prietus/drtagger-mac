import Darwin
import Foundation

// Non-blocking mount table lookup. `getmntinfo(MNT_NOWAIT)` returns the
// kernel's cached statfs entries without contacting any server, so it is
// safe to call even when an NFS mount is wedged.
public enum VolumeInfo {

    public struct Mount: Sendable, Equatable {
        public let mountPoint: String
        public let fileSystem: String     // "apfs", "nfs", "smbfs", …
        public let source: String         // device or server:/export

        public var isNetwork: Bool {
            ["nfs", "smbfs", "afpfs", "webdav", "cifs", "ftp"].contains(fileSystem.lowercased())
        }
    }

    public static func mounts() -> [Mount] {
        var list: UnsafeMutablePointer<statfs>? = nil
        let count = getmntinfo(&list, MNT_NOWAIT)
        guard count > 0, let list else { return [] }
        return (0..<Int(count)).map { i in
            var fs = list[i]
            let mnt = withUnsafePointer(to: &fs.f_mntonname) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
            let type = withUnsafePointer(to: &fs.f_fstypename) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) } }
            let from = withUnsafePointer(to: &fs.f_mntfromname) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
            return Mount(mountPoint: mnt, fileSystem: type, source: from)
        }
    }

    // The mount that holds `path` (longest matching mount point). Automounted
    // shares are listed twice, as "autofs" and as the real file system on the
    // same mount point; the real one wins.
    public static func mount(for path: String) -> Mount? {
        let std = (path as NSString).standardizingPath
        let matches = mounts().filter {
            std == $0.mountPoint || std.hasPrefix($0.mountPoint.hasSuffix("/") ? $0.mountPoint : $0.mountPoint + "/")
        }
        guard let longest = matches.map(\.mountPoint.count).max() else { return nil }
        let best = matches.filter { $0.mountPoint.count == longest }
        return best.first { $0.fileSystem.lowercased() != "autofs" } ?? best.first
    }

    public static func isNetworkVolume(_ url: URL) -> Bool {
        mount(for: url.path)?.isNetwork ?? false
    }
}
