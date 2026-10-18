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
