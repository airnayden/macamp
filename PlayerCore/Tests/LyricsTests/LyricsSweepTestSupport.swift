import Foundation
import GRDB
import Lyrics
import Persistence

/// Seeds `present` tracks so the sweep's anti-join has candidates to page through.
func seedTracks(_ database: AppDatabase, paths: [String]) throws {
    let repository = TrackRepository(database)
    for path in paths {
        _ = try repository.insert(
            TrackRecord(filePath: path, title: URL(fileURLWithPath: path).lastPathComponent)
        )
    }
}

/// Reads the raw `lyricsCache.source` for `key`, so a test can tell a negative
/// sentinel apart from a document without going through ``LyricsCaching/load``.
func cachedSource(_ database: AppDatabase, forKey key: String) throws -> String? {
    try database.writer.read { db in
        try String.fetchOne(db, sql: "SELECT source FROM lyricsCache WHERE cacheKey = ?", arguments: [key])
    }
}

/// A `Sendable` tally the sweep's off-main `onDidCacheLyrics` handler can bump.
final class SignalCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.withLock { value }
    }

    func increment() {
        lock.withLock { value += 1 }
    }
}

/// An ``EmbeddedLyricsReading`` that answers per file path and records every read,
/// so a test can assert the sweep re-opened nothing on a second pass.
final class CountingEmbeddedLyricsReader: EmbeddedLyricsReading, @unchecked Sendable {
    private let lock = NSLock()
    private let embedded: [String: EmbeddedLyrics]
    private var seen: [String] = []

    init(_ embedded: [String: EmbeddedLyrics] = [:]) {
        self.embedded = embedded
    }

    var reads: [String] {
        lock.withLock { seen }
    }

    func readEmbeddedLyrics(from url: URL) throws -> EmbeddedLyrics? {
        lock.withLock {
            seen.append(url.path)
            return embedded[url.path]
        }
    }
}

/// A rendezvous that lets a test observe the first probe and hold every probe
/// until it says otherwise — the barrier that makes concurrency assertions
/// deterministic instead of timing-dependent.
actor ProbeGate {
    private var arrivals = 0
    private var held: [CheckedContinuation<Void, Never>] = []
    private var firstArrival: CheckedContinuation<Void, Never>?
    private var isOpen = false

    var arrivalCount: Int {
        arrivals
    }

    func arrive() async {
        arrivals += 1
        if arrivals == 1 {
            firstArrival?.resume()
            firstArrival = nil
        }
        guard !isOpen else { return }
        await withCheckedContinuation { held.append($0) }
    }

    func waitForFirstArrival() async {
        guard arrivals == 0 else { return }
        await withCheckedContinuation { firstArrival = $0 }
    }

    func open() {
        isOpen = true
        for continuation in held {
            continuation.resume()
        }
        held.removeAll()
    }
}

/// A ``LyricsProviding`` decorator that parks each resolve on a ``ProbeGate``
/// after the underlying resolution completes.
struct GatedLyricsProvider: LyricsProviding {
    let base: any LyricsProviding
    let gate: ProbeGate

    func resolveLyrics(for request: LyricsRequest, options: LyricsOptions) async throws -> Lyrics? {
        let resolved = try await base.resolveLyrics(for: request, options: options)
        await gate.arrive()
        return resolved
    }
}

/// A ``LyricsCaching`` decorator that lets a rival writer win the row **between**
/// a caller's cache miss and its own store — the deterministic stand-in for the
/// sweep racing an online enrichment resolve.
struct RaceLosingLyricsCache: LyricsCaching {
    let base: any LyricsCaching
    let interloper: Lyrics

    func load(forKey key: String) throws -> Lyrics? {
        let cached = try base.load(forKey: key)
        guard cached == nil else { return cached }
        _ = try base.store(interloper, forKey: key)
        return nil
    }

    @discardableResult
    func store(_ lyrics: Lyrics, forKey key: String) throws -> Lyrics {
        try base.store(lyrics, forKey: key)
    }

    func markNoLyrics(forKey key: String) throws {
        try base.markNoLyrics(forKey: key)
    }

    func remove(forKey key: String) throws {
        try base.remove(forKey: key)
    }
}
