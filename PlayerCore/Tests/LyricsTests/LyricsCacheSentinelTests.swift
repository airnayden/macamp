import Foundation
import Lyrics
import Persistence
import Testing

@Suite("LyricsCacheSentinelTests")
struct LyricsCacheSentinelTests {
    private static func synced(_ text: String, source: LyricsSource) -> Lyrics {
        Lyrics(lines: [LyricLine(time: 1, text: text)], source: source)
    }

    // MARK: - Sentinel semantics

    @Test("a sentinel row reads as a miss without decoding its empty payload")
    func sentinelReadsAsMiss() throws {
        let appDB = try AppDatabase.makeEmpty()
        let cache = GRDBLyricsCache(appDB)

        try cache.markNoLyrics(forKey: "/music/a.flac")

        try #expect(cache.load(forKey: "/music/a.flac") == nil)
        try #expect(cachedSource(appDB, forKey: "/music/a.flac") == LyricsCacheSentinel.source)
    }

    @Test("markNoLyrics is idempotent and never overwrites real lyrics")
    func sentinelNeverOverwritesContent() throws {
        let appDB = try AppDatabase.makeEmpty()
        let cache = GRDBLyricsCache(appDB)
        let stored = Self.synced("real", source: .lrclib)
        try cache.store(stored, forKey: "/music/a.flac")

        try cache.markNoLyrics(forKey: "/music/a.flac")
        try cache.markNoLyrics(forKey: "/music/a.flac")

        try #expect(cache.load(forKey: "/music/a.flac") == stored)
    }

    @Test("store overwrites a sentinel even from the lowest-precedence source")
    func storeOverwritesSentinel() throws {
        let appDB = try AppDatabase.makeEmpty()
        let cache = GRDBLyricsCache(appDB)
        try cache.markNoLyrics(forKey: "/music/a.flac")

        let incoming = Self.synced("plain", source: .embeddedUnsynced)
        let returned = try cache.store(incoming, forKey: "/music/a.flac")

        #expect(returned == incoming)
        try #expect(cache.load(forKey: "/music/a.flac") == incoming)
    }

    // MARK: - Precedence monotonicity

    @Test("a lower-precedence store loses and receives the stored winner")
    func storeIsPrecedenceMonotonic() throws {
        let appDB = try AppDatabase.makeEmpty()
        let cache = GRDBLyricsCache(appDB)
        let winner = Self.synced("lrclib", source: .lrclib)
        try cache.store(winner, forKey: "/music/a.flac")

        let returned = try cache.store(Self.synced("plain", source: .embeddedUnsynced), forKey: "/music/a.flac")

        #expect(returned == winner)
        try #expect(cache.load(forKey: "/music/a.flac") == winner)
    }

    @Test("an equal-or-higher-precedence store wins", arguments: [LyricsSource.lrclib, .lrcFile, .embeddedSynced])
    func storeAcceptsEqualOrHigherPrecedence(source: LyricsSource) throws {
        let appDB = try AppDatabase.makeEmpty()
        let cache = GRDBLyricsCache(appDB)
        try cache.store(Self.synced("first", source: .lrclib), forKey: "/music/a.flac")

        let incoming = Self.synced("second", source: source)
        let returned = try cache.store(incoming, forKey: "/music/a.flac")

        #expect(returned == incoming)
        try #expect(cache.load(forKey: "/music/a.flac") == incoming)
    }

    // MARK: - Barrier-controlled concurrent orderings

    @Test("both writer orderings converge on the same winning row")
    func concurrentOrderingsConverge() async throws {
        let sweepResult = Self.synced("embedded", source: .embeddedUnsynced)
        let enrichmentResult = Self.synced("lrclib", source: .lrclib)

        let sweepFirst = try await Self.storeInOrder([sweepResult, enrichmentResult])
        let enrichmentFirst = try await Self.storeInOrder([enrichmentResult, sweepResult])

        #expect(sweepFirst.row == enrichmentResult)
        #expect(enrichmentFirst.row == enrichmentResult)
        #expect(sweepFirst.returned == [sweepResult, enrichmentResult])
        #expect(enrichmentFirst.returned == [enrichmentResult, enrichmentResult])
    }

    @Test("a sentinel written after real lyrics loses in both orderings")
    func sentinelLosesInBothOrderings() async throws {
        let content = Self.synced("real", source: .embeddedUnsynced)

        let sentinelFirst = try await Self.storeInOrder([content], markingFirst: true)
        let sentinelLast = try await Self.storeInOrder([content], markingFirst: false)

        #expect(sentinelFirst.row == content)
        #expect(sentinelLast.row == content)
    }

    /// Runs each store on its own detached task, awaiting each before releasing
    /// the next, so the interleaving is forced rather than raced.
    private static func storeInOrder(
        _ documents: [Lyrics],
        markingFirst: Bool? = nil,
        key: String = "/music/a.flac"
    ) async throws -> (row: Lyrics?, returned: [Lyrics]) {
        let appDB = try AppDatabase.makeEmpty()
        let cache = GRDBLyricsCache(appDB)
        if markingFirst == true { try cache.markNoLyrics(forKey: key) }
        var returned: [Lyrics] = []
        for document in documents {
            let task = Task.detached { try cache.store(document, forKey: key) }
            try await returned.append(task.value)
        }
        if markingFirst == false { try cache.markNoLyrics(forKey: key) }
        return try (cache.load(forKey: key), returned)
    }

    // MARK: - Service + Fake parity

    @Test("a resolve that loses the store race returns the stored winner")
    func resolveReturnsStoredWinner() async throws {
        let appDB = try AppDatabase.makeEmpty()
        let winner = Self.synced("lrclib", source: .lrclib)
        let cache = RaceLosingLyricsCache(base: GRDBLyricsCache(appDB), interloper: winner)
        let service = LyricsService(
            embeddedReader: FakeEmbeddedLyricsReader(EmbeddedLyrics(unsynced: "plain")),
            sidecar: FakeSidecarReader(nil),
            cache: cache
        )

        let resolved = try await service.resolveLyrics(
            for: LyricsRequest(trackURL: URL(fileURLWithPath: "/music/a.flac")),
            options: .offline
        )

        #expect(resolved == winner)
        try #expect(cache.load(forKey: "/music/a.flac") == winner)
    }

    @Test("the fake cache mirrors the GRDB sentinel and precedence semantics")
    func fakeCacheParity() throws {
        let cache = FakeLyricsCache()
        let winner = Self.synced("lrclib", source: .lrclib)

        try cache.markNoLyrics(forKey: "/music/a.flac")
        try #expect(cache.load(forKey: "/music/a.flac") == nil)
        #expect(cache.isNegativeSentinel(forKey: "/music/a.flac"))

        try #expect(cache.store(winner, forKey: "/music/a.flac") == winner)
        #expect(!cache.isNegativeSentinel(forKey: "/music/a.flac"))

        try cache.markNoLyrics(forKey: "/music/a.flac")
        try #expect(cache.load(forKey: "/music/a.flac") == winner)

        let loser = Self.synced("plain", source: .embeddedUnsynced)
        try #expect(cache.store(loser, forKey: "/music/a.flac") == winner)
        try #expect(cache.load(forKey: "/music/a.flac") == winner)
    }
}
