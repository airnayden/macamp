import Foundation
import GRDB
@testable import Lyrics
import Persistence
import Testing

@Suite("LyricsCacheTests")
struct LyricsCacheTests {
    @Test("migration v4 creates lyricsCache and makeEmpty() migrates to head")
    func migrationV4Applies() throws {
        let appDB = try AppDatabase.makeEmpty()
        try appDB.writer.read { db in
            try #expect(db.tableExists("lyricsCache"))
            try #expect(AppDatabase.migrator.appliedMigrations(db) == [
                "v1",
                "v2",
                "v3",
                "v4",
                "v5",
                "v6",
                "v7",
                "v8",
                "v9",
                "v10", "v11", "v12", "v13", "v14", "v15", "v16", "v17", "v18", "v19", "v20", "v21",
            ])
        }
    }

    @Test("GRDB cache round-trips a synced Lyrics value")
    func cacheRoundTrip() throws {
        let appDB = try AppDatabase.makeEmpty()
        let cache = GRDBLyricsCache(appDB)
        let lyrics = Lyrics(
            lines: [
                LyricLine(time: 1, text: "a", words: [TimedWord(time: 1, text: "a")]),
                LyricLine(time: 2, text: "b"),
            ],
            source: .lrcFile,
            metadata: ["ar": "X"],
            offset: 0.5
        )
        try cache.store(lyrics, forKey: "key1")
        try #expect(cache.load(forKey: "key1") == lyrics)
    }

    @Test("storing the same key upserts; remove clears it")
    func cacheUpsertAndRemove() throws {
        let appDB = try AppDatabase.makeEmpty()
        let cache = GRDBLyricsCache(appDB)
        try cache.store(Lyrics(lines: [LyricLine(time: 1, text: "first")], source: .lrcFile), forKey: "key1")
        let updated = Lyrics(lines: [LyricLine(text: "second")], source: .lrcFile)
        try cache.store(updated, forKey: "key1")
        try #expect(cache.load(forKey: "key1") == updated)
        try cache.remove(forKey: "key1")
        try #expect(cache.load(forKey: "key1") == nil)
    }

    @Test("a cache hit means the online seam is not queried again")
    func serviceCacheHitAvoidsRefetch() async throws {
        let appDB = try AppDatabase.makeEmpty()
        let mock = MockOnlineLyricsFetcher(returning: OnlineLyricsResult(syncedLyrics: "[00:01.00]net"))
        let service = LyricsService(
            embeddedReader: FakeEmbeddedLyricsReader(nil),
            sidecar: FakeSidecarReader(nil),
            lrclib: mock,
            cache: GRDBLyricsCache(appDB)
        )
        let request = LyricsRequest(title: "T", artist: "A")

        let first = try await service.resolveLyrics(for: request, options: .online)
        #expect(first?.source == .lrclib)
        #expect(mock.fetchCount == 1)

        let second = try await service.resolveLyrics(for: request, options: .online)
        #expect(second?.source == .lrclib)
        #expect(mock.fetchCount == 1)
    }
}
