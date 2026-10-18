import FLACKit
import Foundation
import LibraryKit

public struct TagWriteReport: Sendable, Codable, Equatable, Hashable {
    public let path: String
    public let container: TagContainer
    public let audioDigest: String
    public let bytesWritten: Int64
    public let pictureCount: Int

    public init(path: String, container: TagContainer, audioDigest: String, bytesWritten: Int64, pictureCount: Int) {
        self.path = path; self.container = container; self.audioDigest = audioDigest; self.bytesWritten = bytesWritten; self.pictureCount = pictureCount
    }

    public func moved(to path: String) -> TagWriteReport {
        TagWriteReport(path: path, container: container, audioDigest: audioDigest, bytesWritten: bytesWritten, pictureCount: pictureCount)
    }
}

// Everything needed to put a file's metadata back exactly as it was.
public struct TagBackup: Sendable, Codable, Equatable, Hashable {
    public let path: String
    public let container: TagContainer
    public let rawMetadata: Data
    public let audioDigest: String
    public let tags: TagSet
    public let pictures: [PictureInfo]
    public let createdAt: Date

    public init(url: URL, container: TagContainer, contents: ContainerContents) {
        path = url.path; self.container = container; rawMetadata = contents.rawMetadata; audioDigest = contents.audioDigest
        tags = contents.tags; pictures = contents.pictures.map(PictureInfo.init); createdAt = Date()
    }

    public init(path: String, container: TagContainer, rawMetadata: Data, audioDigest: String, tags: TagSet, pictures: [PictureInfo], createdAt: Date) {
        self.path = path; self.container = container; self.rawMetadata = rawMetadata; self.audioDigest = audioDigest
        self.tags = tags; self.pictures = pictures; self.createdAt = createdAt
    }

    public func moved(to path: String) -> TagBackup {
        TagBackup(path: path, container: container, rawMetadata: rawMetadata, audioDigest: audioDigest, tags: tags, pictures: pictures, createdAt: createdAt)
    }
}

// One entry point per file; dispatches on the container.
public enum TaggedFile {

    public static func container(for url: URL) throws -> TagContainer {
        guard let c = TagContainer.from(url: url) else { throw TagFileError.unsupportedContainer(url.pathExtension) }
        return c
    }

    public static func read(_ url: URL) throws -> ContainerContents {
        let url = url.onDisk
        switch try container(for: url) {
        case .flac: return try FLACContainer.read(url: url)
        case .dsf: return try DSFContainer.read(url: url)
        case .wav: return try IFFContainer(flavor: .wav).read(url: url)
        case .aiff: return try IFFContainer(flavor: .aiff).read(url: url)
        case .dff: return try IFFContainer(flavor: .dff).read(url: url)
        case .ape: return try APEContainer.read(url: url)
        case .mp4: return try MP4Container.read(url: url)
        }
    }

    // Tags only: no audio is read (no digest, no picture payloads), so it is
    // cheap enough for indexing a whole library over the network.
    public static func readTags(_ url: URL) throws -> TagSet {
        let url = url.onDisk
        switch try container(for: url) {
        case .flac: return try FLACContainer.read(url: url, withDigest: false, withPictures: false).tags
        case .dsf: return try DSFContainer.read(url: url, withDigest: false).tags
        case .wav: return try IFFContainer(flavor: .wav).read(url: url, withDigest: false).tags
        case .aiff: return try IFFContainer(flavor: .aiff).read(url: url, withDigest: false).tags
        case .dff: return try IFFContainer(flavor: .dff).read(url: url, withDigest: false).tags
        case .ape: return try APEContainer.read(url: url, withDigest: false).tags
        case .mp4: return try MP4Container.read(url: url, withDigest: false).tags
        }
    }

    // Tags and pictures without hashing the audio: enough to preview what
    // a write would change (the write itself verifies the audio).
    public static func readForPreview(_ url: URL) throws -> ContainerContents {
        let url = url.onDisk
        switch try container(for: url) {
        case .flac: return try FLACContainer.read(url: url, withDigest: false)
        case .dsf: return try DSFContainer.read(url: url, withDigest: false)
        case .wav: return try IFFContainer(flavor: .wav).read(url: url, withDigest: false)
        case .aiff: return try IFFContainer(flavor: .aiff).read(url: url, withDigest: false)
        case .dff: return try IFFContainer(flavor: .dff).read(url: url, withDigest: false)
        case .ape: return try APEContainer.read(url: url, withDigest: false)
        case .mp4: return try MP4Container.read(url: url, withDigest: false)
        }
    }

    public static func backup(_ url: URL) throws -> TagBackup {
        TagBackup(url: url, container: try container(for: url), contents: try read(url))
    }

    // `pictures`: nil keeps the file's pictures, [] removes them, otherwise
    // they are replaced. The audio payload is hashed while it is copied and
    // compared with the original; a mismatch leaves the original untouched.
    @discardableResult
    public static func write(_ url: URL, tags: TagSet, pictures: [Picture]? = nil, expectedDigest: String? = nil) throws -> TagWriteReport {
        let url = url.onDisk
        let kind = try container(for: url)
        let before = try expectedDigest ?? read(url).audioDigest
        return try replacing(url, kind: kind, expectedDigest: before, pictureCount: pictures?.count ?? -1) { out in
            switch kind {
            case .flac: return try FLACContainer.write(url: url, tags: tags, pictures: pictures, to: out)
            case .dsf: return try DSFContainer.write(url: url, tags: tags, pictures: pictures, to: out)
            case .wav: return try IFFContainer(flavor: .wav).write(url: url, tags: tags, pictures: pictures, to: out)
            case .aiff: return try IFFContainer(flavor: .aiff).write(url: url, tags: tags, pictures: pictures, to: out)
            case .dff: return try IFFContainer(flavor: .dff).write(url: url, tags: tags, pictures: pictures, to: out)
            case .ape: return try APEContainer.write(url: url, tags: tags, pictures: pictures, to: out)
            case .mp4: return try MP4Container.write(url: url, tags: tags, pictures: pictures, to: out)
            }
        }
    }

    @discardableResult
    public static func restore(_ url: URL, from backup: TagBackup) throws -> TagWriteReport {
        let url = url.onDisk
        let kind = try container(for: url)
        return try replacing(url, kind: kind, expectedDigest: backup.audioDigest, pictureCount: backup.pictures.count) { out in
            switch kind {
            case .flac: return try FLACContainer.restore(url: url, rawMetadata: backup.rawMetadata, to: out)
            case .dsf: return try DSFContainer.restore(url: url, rawMetadata: backup.rawMetadata, to: out)
            case .wav: return try IFFContainer(flavor: .wav).restore(url: url, rawMetadata: backup.rawMetadata, to: out)
            case .aiff: return try IFFContainer(flavor: .aiff).restore(url: url, rawMetadata: backup.rawMetadata, to: out)
            case .dff: return try IFFContainer(flavor: .dff).restore(url: url, rawMetadata: backup.rawMetadata, to: out)
            case .ape: return try APEContainer.restore(url: url, rawMetadata: backup.rawMetadata, to: out)
            case .mp4: return try MP4Container.restore(url: url, rawMetadata: backup.rawMetadata, to: out)
            }
        }
    }

    // Existing pictures with the front cover swapped (or added).
    public static func replacingFront(in existing: [Picture], with front: Picture) -> [Picture] {
        [front] + existing.filter { !$0.isFront }
    }

    private static func replacing(_ url: URL, kind: TagContainer, expectedDigest: String, pictureCount: Int, body: (FileHandle) throws -> String) throws -> TagWriteReport {
        // The temporary file lives next to the original, built from the
        // original's exact path bytes (NFC names on network shares).
        let tmp = URL(fileURLWithPath: url.deletingLastPathComponent().path + "/." + url.lastPathComponent + ".drtagger.tmp").onDisk
        let fm = FileManager.default
        try? fm.removeItem(at: tmp)
        let fd = tmp.path.withCString { open($0, O_WRONLY | O_CREAT | O_TRUNC, 0o644) }
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let out = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var digest = ""
        do {
            digest = try body(out)
            try out.synchronize()
            try out.close()
        } catch {
            try? out.close(); try? fm.removeItem(at: tmp)
            throw error
        }
        guard digest == expectedDigest else {
            try? fm.removeItem(at: tmp)
            throw TagFileError.audioChanged(expected: expectedDigest, actual: digest)
        }
        let size = (try? tmp.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
        _ = try fm.replaceItemAt(url, withItemAt: tmp)
        if let created {
            var u = url
            var values = URLResourceValues()
            values.creationDate = created
            try? u.setResourceValues(values)
        }
        return TagWriteReport(path: url.path, container: kind, audioDigest: digest, bytesWritten: size, pictureCount: max(0, pictureCount))
    }
}
