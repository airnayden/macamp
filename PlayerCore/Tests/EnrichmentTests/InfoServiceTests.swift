// InfoServiceTests — the cache store + cache-first service + enrichment prefetch,
// all driven through an in-memory database and the network-free MockInfoFetcher.
import Foundation
import Lyrics
import Metadata
import Persistence
import PlayerCoreTestSupport
import Services
import Testing

@Suite("InfoServiceTests")
struct InfoServiceTests {
    // MARK: - InfoCacheStore

    @Test("the store round-trips and upserts by (entityType, entityKey)")
    func cacheRoundTripUpsert() async throws {
        let database = try AppDatabase.makeEmpty()
        let store = InfoCacheStore(database)
        try await store.store(AlbumInfo(description: "First"), entityType: "album", entityKey: "A|B")
        var loaded = try await store.load(AlbumInfo.self, entityType: "album", entityKey: "A|B")
        #expect(loaded?.description == "First")

        try await store.store(AlbumInfo(description: "Second"), entityType: "album", entityKey: "A|B")
        loaded = try await store.load(AlbumInfo.self, entityType: "album", entityKey: "A|B")
        #expect(loaded?.description == "Second")
    }

    @Test("a cached entry older than maxAge is treated as a miss")
    func cacheExpiry() async throws {
        let database = try AppDatabase.makeEmpty()
        let store = InfoCacheStore(database, maxAge: 30 * 86400)
        let base = 1_000_000.0
        try await store.store(ArtistInfo(biography: "Old"), entityType: "artist", entityKey: "X", now: base)

        let fresh = try await store.load(ArtistInfo.self, entityType: "artist", entityKey: "X", now: base + 86400)
        #expect(fresh?.biography == "Old")

        let expired = try await store.load(
            ArtistInfo.self, entityType: "artist", entityKey: "X", now: base + 31 * 86400
        )
        #expect(expired == nil)
    }

    // MARK: - InfoService cache-first

    @Test("artistInfo caches on miss then serves from cache without refetching")
    func artistInfoCacheFirst() async throws {
        let database = try AppDatabase.makeEmpty()
        let mock = MockInfoFetcher(artist: ArtistInfo(biography: "Bio", tags: ["rock"]))
        let service = InfoService(fetcher: mock, database: database)

        let first = await service.artistInfo(name: "Pink Floyd", mbid: nil)
        #expect(first?.biography == "Bio")
        #expect(mock.queries.count == 1)

        let second = await service.artistInfo(name: "Pink Floyd", mbid: nil)
        #expect(second?.biography == "Bio")
        #expect(mock.queries.count == 1)
    }

    @Test("a no-match fetch returns nil and is not cached")
    func missReturnsNil() async throws {
        let database = try AppDatabase.makeEmpty()
        let mock = MockInfoFetcher()
        let service = InfoService(fetcher: mock, database: database)
        let result = await service.trackInfo(title: "Unknown", artist: "Nobody", mbid: nil)
        #expect(result == nil)
        let store = InfoCacheStore(database)
        let cached = try await store.load(TrackInfo.self, entityType: "track", entityKey: "Nobody|Unknown")
        #expect(cached == nil)
    }

    @Test("albumInfo caches under the artist|title key")
    func albumKeyFormat() async throws {
        let database = try AppDatabase.makeEmpty()
        let mock = MockInfoFetcher(album: AlbumInfo(description: "Story"))
        let service = InfoService(fetcher: mock, database: database)
        _ = await service.albumInfo(title: "The Wall", artist: "Pink Floyd", mbid: nil)

        let store = InfoCacheStore(database)
        let cached = try await store.load(AlbumInfo.self, entityType: "album", entityKey: "Pink Floyd|The Wall")
        #expect(cached?.description == "Story")
    }

    @Test("a blank title resolves no info and performs no fetch")
    func blankTitleNoFetch() async throws {
        let database = try AppDatabase.makeEmpty()
        let mock = MockInfoFetcher(track: TrackInfo(description: "X"))
        let service = InfoService(fetcher: mock, database: database)
        let result = await service.trackInfo(title: "   ", artist: "A", mbid: nil)
        #expect(result == nil)
        #expect(mock.queries.isEmpty)
    }

    // MARK: - Enrichment prefetch integration

    @MainActor
    @Test("enrichment pre-populates the info cache for the track + its artist")
    func enrichmentPrefetchesInfo() async throws {
        let database = try AppDatabase.makeEmpty()
        let url = try makeTempAudioFile(ext: "mp3")
        _ = try insertTrack(
            database,
            TrackRecord(filePath: url.path, title: "Money", artistName: "Pink Floyd", availability: .present)
        )
        let infoMock = MockInfoFetcher(artist: ArtistInfo(biography: "Bio"), track: TrackInfo(description: "Desc"))
        let service = EnrichmentService(
            database: database,
            metadataFetcher: StubMetadataFetcher(returning: nil),
            metadataWriter: FakeMetadataWriter(),
            lyricsProvider: FakeLyricsProvider(),
            infoService: InfoService(fetcher: infoMock, database: database)
        )

        service.start()
        await pollUntil { !service.isRunning }

        let store = InfoCacheStore(database)
        let artist = try await store.load(ArtistInfo.self, entityType: "artist", entityKey: "Pink Floyd")
        let track = try await store.load(TrackInfo.self, entityType: "track", entityKey: "Pink Floyd|Money")
        #expect(artist?.biography == "Bio")
        #expect(track?.description == "Desc")
        #expect(infoMock.queries.count == 2)
    }
}
