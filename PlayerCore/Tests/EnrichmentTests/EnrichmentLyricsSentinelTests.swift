// EnrichmentLyricsSentinelTests — the exact predicate for writing a negative
// result from the ONLINE enrichment lane.
//
// The lane writes a sentinel only when the resolve RETURNED NIL WITHOUT THROWING
// **and** the request carried a non-blank title. A throw is a transient failure
// (mirroring ``LyricsSweepService``'s offline precedent), and a blank title never
// reaches LRCLIB's `/api/search` fallback, so neither is evidence that the service
// has nothing. Both must leave the row absent so the track is asked about again.
import Foundation
import GRDB
import Lyrics
import Metadata
import Persistence
import PlayerCoreTestSupport
import Services
import Testing

@MainActor
@Suite("EnrichmentLyricsSentinelTests")
struct EnrichmentLyricsSentinelTests {
    @Test("a titled track the service has no lyrics for is sentineled exactly once")
    func titledNoMatchWritesOneSentinel() async throws {
        let database = try AppDatabase.makeEmpty()
        let path = "/fixtures/complete-0.mp3"
        try insertTrack(database, metadataCompleteTrack(path: path, title: "Complete 0", artist: "Artist 0"))
        let lyrics = RecordingLyricsProvider()
        let service = makeService(database, lyrics: lyrics)

        service.start()
        await pollUntil { !service.isRunning }

        #expect(lyrics.requests.count == 1)
        #expect(lyrics.noMatchCacheKeys == [path])
    }

    @Test("a throwing resolve writes no sentinel and still completes the track")
    func throwingResolveWritesNoSentinel() async throws {
        let database = try AppDatabase.makeEmpty()
        try seedComplete(database, count: 3)
        let lyrics = RecordingLyricsProvider(throwing: true)
        let service = makeService(database, lyrics: lyrics)

        service.start()
        await pollUntil(timeout: .seconds(20)) { !service.isRunning }

        #expect(lyrics.requests.count == 3)
        #expect(lyrics.noMatchCacheKeys.isEmpty)
        #expect(service.progress.completed == 3)
        #expect(service.progress.completed == service.progress.total)
    }

    @Test("a blank-title track is resolved but never sentineled")
    func blankTitleWritesNoSentinel() async throws {
        let database = try AppDatabase.makeEmpty()
        try insertTrack(database, TrackRecord(filePath: "/fixtures/untitled.mp3", availability: .present))
        let lyrics = RecordingLyricsProvider()
        let service = makeService(database, lyrics: lyrics)

        service.start()
        await pollUntil { !service.isRunning }

        #expect(lyrics.requests.count == 1)
        #expect(lyrics.noMatchCacheKeys.isEmpty)
    }

    @Test("a mixed page sentinels only the titled no-matches")
    func mixedPageSentinelsOnlyTitledNoMatches() async throws {
        let database = try AppDatabase.makeEmpty()
        let noMatch = "/fixtures/complete-0.mp3"
        let found = "/fixtures/complete-1.mp3"
        try insertTrack(database, metadataCompleteTrack(path: noMatch, title: "Complete 0", artist: "Artist 0"))
        try insertTrack(database, metadataCompleteTrack(path: found, title: "Complete 1", artist: "Artist 1"))
        try insertTrack(database, TrackRecord(filePath: "/fixtures/untitled.mp3", availability: .present))
        let lyrics = RecordingLyricsProvider(
            documents: [found: Lyrics(lines: [LyricLine(text: "la la la")], source: .lrclib)]
        )
        let service = makeService(database, lyrics: lyrics)

        service.start()
        await pollUntil(timeout: .seconds(20)) { !service.isRunning }

        #expect(lyrics.requests.count == 3)
        #expect(lyrics.noMatchCacheKeys == [noMatch])
        #expect(service.progress.completed == 3)
    }

    // MARK: - The decided consequence

    /// DECIDED, not incidental: an enrichment-written sentinel also retires the
    /// track from the OFFLINE sweep, because the sweep's anti-join treats ANY
    /// `lyricsCache` row as probed. That is intended — an online no-match implies
    /// the local sources were already swept at import and LRCLIB has nothing
    /// either. A later online success still wins, since the store is monotonic and
    /// a sentinel always loses.
    @Test("an enrichment sentinel retires the track from the sweep, and a later online success still overwrites it")
    func sentinelRetiresTrackFromSweepAndStillYieldsToOnlineSuccess() async throws {
        let database = try AppDatabase.makeEmpty()
        let path = "/fixtures/complete-0.mp3"
        try insertTrack(database, metadataCompleteTrack(path: path, title: "Complete 0", artist: "Artist 0"))
        let cache = GRDBLyricsCache(database)
        let service = makeService(database, lyrics: Self.lyricsService(cache: cache, fetching: nil))

        service.start()
        await pollUntil { !service.isRunning }

        try #expect(cachedSource(database, forKey: path) == LyricsCacheSentinel.source)
        try #expect(cache.load(forKey: path) == nil)
        try await #expect(TrackRepository(database).filePathsWithoutLyricsProbe(limit: 100).isEmpty)

        let online = Self.lyricsService(cache: cache, fetching: OnlineLyricsResult(syncedLyrics: "[00:01.00]net"))
        let resolved = try await online.resolveLyrics(
            for: LyricsRequest(trackURL: URL(fileURLWithPath: path)),
            options: .online
        )

        #expect(resolved?.source == .lrclib)
        try #expect(cache.load(forKey: path)?.source == .lrclib)
    }
}

// MARK: - Fixtures

private extension EnrichmentLyricsSentinelTests {
    func makeService(_ database: AppDatabase, lyrics: any LyricsProviding) -> EnrichmentService {
        EnrichmentService(
            database: database,
            metadataFetcher: StubMetadataFetcher(returning: nil),
            metadataWriter: FakeMetadataWriter(),
            lyricsProvider: lyrics
        )
    }

    /// A real ``LyricsService`` over a real GRDB cache with no offline sources, so
    /// the whole write path — resolve → `noteOnlineNoMatch` → sentinel row — runs.
    static func lyricsService(cache: GRDBLyricsCache, fetching result: OnlineLyricsResult?) -> LyricsService {
        LyricsService(
            embeddedReader: FakeEmbeddedLyricsReader(nil),
            sidecar: FakeSidecarReader(nil),
            lrclib: MockOnlineLyricsFetcher(returning: result),
            cache: cache
        )
    }

    @discardableResult
    func seedComplete(_ database: AppDatabase, count: Int) throws -> [String] {
        try (0 ..< count).map { index in
            let path = "/fixtures/complete-\(index).mp3"
            try insertTrack(
                database,
                metadataCompleteTrack(path: path, title: "Complete \(index)", artist: "Artist \(index)")
            )
            return path
        }
    }

    /// Reads the raw `source` column so a sentinel row is distinguishable from an
    /// absent row — `load` reports both as `nil`.
    func cachedSource(_ database: AppDatabase, forKey key: String) throws -> String? {
        try database.writer.read { db in
            try String.fetchOne(db, sql: "SELECT source FROM lyricsCache WHERE cacheKey = ?", arguments: [key])
        }
    }
}

/// A ``LyricsProviding`` that resolves from a canned table (missing entries resolve
/// to `nil`, or throw when `throwing`) and records every sentinel it is asked to
/// write — so a test can assert on the predicate rather than on cache side effects.
private final class RecordingLyricsProvider: LyricsProviding, @unchecked Sendable {
    struct ResolveFailure: Error {}

    private let documents: [String: Lyrics]
    private let throwsOnResolve: Bool
    private let lock = NSLock()
    private var seen: [LyricsRequest] = []
    private var noMatches: [String] = []

    init(documents: [String: Lyrics] = [:], throwing: Bool = false) {
        self.documents = documents
        throwsOnResolve = throwing
    }

    var requests: [LyricsRequest] {
        lock.withLock { seen }
    }

    var noMatchCacheKeys: [String] {
        lock.withLock { noMatches }
    }

    func resolveLyrics(for request: LyricsRequest, options _: LyricsOptions) async throws -> Lyrics? {
        lock.withLock { seen.append(request) }
        if throwsOnResolve { throw ResolveFailure() }
        return documents[request.cacheKey]
    }

    func noteOnlineNoMatch(forKey cacheKey: String) async {
        lock.withLock { noMatches.append(cacheKey) }
    }
}
