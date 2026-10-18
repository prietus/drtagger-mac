import Foundation

// File names with accents are stored by APFS in decomposed form (NFD) and
// by Linux NFS / SMB servers as written, usually composed (NFC). Foundation
// turns a path *string* into decomposed bytes when it builds a file URL
// from it (URL(fileURLWithPath:), appending components, Codable round
// trips, FileManager's path APIs), which on such a share names a file that
// does not exist. These helpers keep the exact bytes of the path.
public extension URL {
    // The same location, using the path's bytes as they are.
    var onDisk: URL {
        guard isFileURL else { return self }
        let dir = hasDirectoryPath
        return path.withCString { URL(fileURLWithFileSystemRepresentation: $0, isDirectory: dir, relativeTo: nil) }
    }

    var existsOnDisk: Bool { path.withCString { access($0, F_OK) == 0 } }

    var isDirectoryOnDisk: Bool {
        var st = stat()
        return path.withCString { stat($0, &st) } == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }
}

public extension DetectedTrackFile {
    func onDisk() -> DetectedTrackFile { DetectedTrackFile(url: url.onDisk, format: format, fileSize: fileSize) }
}

public extension DetectedAlbum {
    // Every URL of the album with its exact on-disk bytes (stored albums are
    // decoded from JSON, which goes through path strings).
    func onDisk() -> DetectedAlbum {
        var a = self
        a.url = url.onDisk
        a.isoFile = isoFile?.onDisk()
        a.artworkFiles = artworkFiles.map(\.onDisk)
        a.discs = discs.map { d in
            var d = d
            d.folder = d.folder.onDisk
            d.cueURL = d.cueURL?.onDisk
            d.imageFile = d.imageFile?.onDisk()
            d.trackFiles = d.trackFiles.map { $0.onDisk() }
            d.artworkFiles = d.artworkFiles.map(\.onDisk)
            d.logFiles = d.logFiles.map(\.onDisk)
            return d
        }
        return a
    }
}

// Process (NSTask) passes its arguments through the file system
// representation, which decomposes accents: ffmpeg is handed "Barón" as
// "Baro\u{301}n" and finds nothing on a share that stores "Barón". Paths
// with non-ASCII characters are handed over as an ASCII symbolic link to
// the exact bytes (outputs: a link to their folder).
public enum ProcessPaths {
    public static func argument(_ arg: String) -> String {
        guard arg.hasPrefix("/"), !arg.allSatisfy(\.isASCII) else { return arg }
        if arg.withCString({ access($0, F_OK) }) == 0 {
            let ext = (arg as NSString).pathExtension
            return link(to: arg, suffix: ext.isEmpty || !ext.allSatisfy(\.isASCII) ? "" : "." + ext) ?? arg
        }
        let parent = (arg as NSString).deletingLastPathComponent
        guard parent != arg, parent.withCString({ access($0, F_OK) }) == 0, let dir = link(to: parent, suffix: "") else { return arg }
        return dir + "/" + (arg as NSString).lastPathComponent
    }

    static let directory: String = {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("drtagger-paths")
        mkdir(dir, 0o700)
        return dir
    }()

    static func link(to target: String, suffix: String) -> String? {
        // FNV-1a of the exact bytes: one stable link per path.
        var hash: UInt64 = 0xcbf29ce484222325
        for b in target.utf8 { hash = (hash ^ UInt64(b)) &* 0x100000001b3 }
        let path = directory + "/" + String(hash, radix: 16) + suffix
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let n = path.withCString { readlink($0, &buffer, buffer.count - 1) }
        if n >= 0, String(decoding: buffer[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self).utf8.elementsEqual(target.utf8) { return path }
        _ = path.withCString { unlink($0) }
        let ok = target.withCString { t in path.withCString { symlink(t, $0) } } == 0
        return ok ? path : nil
    }
}
