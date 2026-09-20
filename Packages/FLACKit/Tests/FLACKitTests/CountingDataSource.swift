import Foundation
@testable import FLACKit

// Test double that proxies another source and tallies bytes served.
// Used to assert tag-only reads stay under NAS-friendly thresholds.
final class CountingDataSource: FLACDataSource, @unchecked Sendable {
    let inner: any FLACDataSource
    private(set) var bytesRead: Int = 0
    private(set) var reads: Int = 0
    private let lock = NSLock()

    init(_ inner: any FLACDataSource) { self.inner = inner }

    var length: UInt64 { get throws { try inner.length } }

    func read(at offset: UInt64, length: Int) throws -> Data {
        lock.lock()
        bytesRead += length
        reads += 1
        lock.unlock()
        return try inner.read(at: offset, length: length)
    }
}
