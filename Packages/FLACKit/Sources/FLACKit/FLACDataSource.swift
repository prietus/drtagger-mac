import Foundation

// A random-access byte source the FLAC parser reads from.
//
// Two adapters ship in-package:
//   - FileHandleDataSource: local files and iOS FileProvider-backed files
//   - DataDataSource: in-memory buffers, for tests and for WebDAV bodies
//     the network layer has already downloaded
//
// A third adapter (HTTP Range) lives in the app layer so FLACKit stays
// dependency-free and testable on pure Foundation.

public protocol FLACDataSource: Sendable {
    var length: UInt64 { get throws }
    func read(at offset: UInt64, length: Int) throws -> Data
}

public struct DataDataSource: FLACDataSource {
    public let data: Data
    public init(_ data: Data) { self.data = data }
    public var length: UInt64 { UInt64(data.count) }
    public func read(at offset: UInt64, length: Int) throws -> Data {
        let start = Int(offset)
        let end = start + length
        guard end <= data.count else { throw FLACError.truncated }
        return data.subdata(in: start..<end)
    }
}

// Sparse data source that holds two non-contiguous byte regions (a head
// and a tail) without allocating the gap between them. Used for big DSF
// files where the header is at offset 0 and the ID3v2 tag is hundreds of
// MB later at the end of the file. Reads that fall in the gap return zeros.
public struct SparseDataSource: FLACDataSource {
    private let head: Data
    private let tail: Data
    private let tailOffset: UInt64
    private let _length: UInt64

    public init(head: Data, tail: Data, tailOffset: UInt64, totalLength: UInt64) {
        self.head = head
        self.tail = tail
        self.tailOffset = tailOffset
        self._length = totalLength
    }

    public var length: UInt64 { _length }

    public func read(at offset: UInt64, length: Int) throws -> Data {
        let end = offset + UInt64(length)
        let headEnd = UInt64(head.count)
        let tailEnd = tailOffset + UInt64(tail.count)

        // Fully within the head region.
        if offset < headEnd, end <= headEnd {
            let s = Int(offset)
            return head.subdata(in: s..<(s + length))
        }
        // Fully within the tail region.
        if offset >= tailOffset, end <= tailEnd {
            let s = Int(offset - tailOffset)
            return tail.subdata(in: s..<(s + length))
        }
        // Spans the gap or is entirely in the gap — return zeros.
        // The DSF parser only reads at known offsets (header, fmt, data
        // header, metadataPointer) so cross-region reads shouldn't
        // happen in practice.
        return Data(count: length)
    }
}

// FileHandleDataSource is NOT Sendable-safe on its own because FileHandle
// maintains internal cursor state. We serialize all access behind an actor-
// free lock so a single source can still be passed across concurrency
// domains (Swift 6 strict concurrency requires the conformance).

public final class FileHandleDataSource: FLACDataSource, @unchecked Sendable {
    private let handle: FileHandle
    private let totalLength: UInt64
    private let lock = NSLock()

    public init(url: URL) throws {
        let h = try FileHandle(forReadingFrom: url)
        self.handle = h
        let end = try h.seekToEnd()
        try h.seek(toOffset: 0)
        self.totalLength = end
    }

    deinit { try? handle.close() }

    public var length: UInt64 { totalLength }

    public func read(at offset: UInt64, length: Int) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: length), data.count == length else {
            throw FLACError.truncated
        }
        return data
    }
}
