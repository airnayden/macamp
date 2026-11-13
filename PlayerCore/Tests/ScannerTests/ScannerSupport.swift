// Local test support for the library scanner suite.
//
// A local SQL trace + fixtures (cannot import LibraryTests' helpers — separate
// test target). `Persistence`/`Metadata` resolve transitively through `Services`
// (same as CoordinatorTests), so no extra Package.swift dependency is needed.
import Foundation
import GRDB
import Metadata
import Persistence
@testable import Services

/// Thread-safe SQL statement collector (a local copy of LibraryTests' helper),
/// installed on every connection to count transaction boundaries.
final class ScanSQLTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [String] = []

    func record(_ sql: String) {
        lock.lock()
        collected.append(sql)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        collected = []
        lock.unlock()
    }

    func count(matching needle: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let upper = needle.uppercased()
        return collected.count { $0.uppercased().contains(upper) }
    }
}

enum ScannerFixtures {
    /// An in-memory migrated database whose every SQL statement is traced. The
    /// trace is reset after migration so only scan-time statements are counted.
    static func makeTracedDatabase() throws -> (AppDatabase, ScanSQLTrace) {
        let trace = ScanSQLTrace()
        var config = Configuration()
        config.prepareDatabase { db in
            db.trace(options: .statement) { event in
                if case let .statement(statement) = event {
                    trace.record(statement.sql)
                }
            }
        }
        let appDB = try AppDatabase(DatabaseQueue(configuration: config))
        trace.reset()
        return (appDB, trace)
    }

    /// Pre-fingerprinted synthetic candidates (deterministic mtime/size per index,
    /// so a re-scan of the same manifest skips them).
    static func syntheticCandidates(_ count: Int) -> [ScanCandidate] {
        (0 ..< count).map { index in
            ScanCandidate(
                url: URL(fileURLWithPath: "/synthetic/\(index).flac"),
                mtime: Double(index),
                fileSize: Int64(1000 + index)
            )
        }
    }

    static func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scanner-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    static func writeFile(in dir: URL, name: String, bytes: Int = 16) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(repeating: 0xAB, count: bytes).write(to: url)
        return url
    }
}

/// A ``MetadataReading`` that lets only `permits` reads succeed immediately;
/// further reads block (polling cancellation) until the scan is cancelled, then
/// bail. This makes the resumable-cancellation test deterministic: the second
/// chunk's metadata reads cannot finish — so the chunk cannot persist — until
/// cancellation drops it. `maxWait` bounds the spin so a broken-cancellation run
/// fails loudly instead of hanging forever.
final class GatedMetadataReader: MetadataReading, @unchecked Sendable {
    let base: TrackMetadata
    private let lock = NSLock()
    private var remaining: Int
    private let maxWait: TimeInterval

    init(base: TrackMetadata, permits: Int, maxWait: TimeInterval = 5) {
        self.base = base
        remaining = permits
        self.maxWait = maxWait
    }

    func readMetadata(from _: URL) throws -> TrackMetadata {
        if takePermit() {
            return base
        }
        let deadline = Date().addingTimeInterval(maxWait)
        while Date() < deadline {
            if Task.isCancelled || takePermit() {
                return base
            }
            Thread.sleep(forTimeInterval: 0.002)
        }
        return base
    }

    private func takePermit() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard remaining > 0 else {
            return false
        }
        remaining -= 1
        return true
    }
}
