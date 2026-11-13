import Foundation
import Lyrics
import Persistence
import Services
import Testing

@Suite("LyricsSweepTests")
@MainActor
struct LyricsSweepTests {
    private static let withLyrics = "/music/a.flac"
    private static let withoutLyrics = ["/music/b.flac", "/music/c.flac"]
    private static var allPaths: [String] {
        [withLyrics] + withoutLyrics
    }

    private struct Fixture {
        let database: AppDatabase
        let cache: GRDBLyricsCache
        let reader: CountingEmbeddedLyricsReader
        let fetcher: MockOnlineLyricsFetcher
        let provider: any LyricsProviding
    }

    /// A launch: a fresh reader/fetcher over the same database, so a second call
    /// measures exactly what the *next* app launch would re-read.
    private static func launch(_ database: AppDatabase) -> Fixture {
        let cache = GRDBLyricsCache(database)
        let reader = CountingEmbeddedLyricsReader([withLyrics: EmbeddedLyrics(unsynced: "la la la")])
        let fetcher = MockOnlineLyricsFetcher(returning: OnlineLyricsResult(plainLyrics: "from the network"))
        return Fixture(
            database: database,
            cache: cache,
            reader: reader,
            fetcher: fetcher,
            provider: LyricsService(
                embeddedReader: reader,
                sidecar: FakeSidecarReader(nil),
                lrclib: fetcher,
                cache: cache
            )
        )
    }

    private static func sweep(
        _ fixture: Fixture,
        provider: (any LyricsProviding)? = nil,
        chunkSize: Int = 2
    ) -> LyricsSweepService {
        LyricsSweepService(
            repository: TrackRepository(fixture.database),
            lyricsProvider: provider ?? fixture.provider,
            cache: fixture.cache,
            chunkSize: chunkSize
        )
    }

    private static func unprobed(_ database: AppDatabase) async throws -> [String] {
        try await TrackRepository(database)
            .filePathsWithoutLyricsProbe(limit: 100)
            .map(\.filePath)
    }

    // MARK: - The pass

    @Test("the sweep stores offline lyrics and sentinels the rest, never touching the network")
    func sweepFillsCacheOffline() async throws {
        let database = try AppDatabase.makeEmpty()
        try seedTracks(database, paths: Self.allPaths)
        let fixture = Self.launch(database)

        let service = Self.sweep(fixture)
        service.start()
        await service.waitForCompletion()

        try #expect(fixture.cache.load(forKey: Self.withLyrics)?.plainText == "la la la")
        for path in Self.withoutLyrics {
            try #expect(fixture.cache.load(forKey: path) == nil)
            try #expect(cachedSource(database, forKey: path) == LyricsCacheSentinel.source)
        }
        #expect(fixture.fetcher.fetchCount == 0)
        try await #expect(Self.unprobed(database).isEmpty)
    }

    @Test("a second launch re-opens nothing")
    func secondLaunchIsAZeroResolvePass() async throws {
        let database = try AppDatabase.makeEmpty()
        try seedTracks(database, paths: Self.allPaths)
        let first = Self.launch(database)
        let firstService = Self.sweep(first)
        firstService.start()
        await firstService.waitForCompletion()

        let second = Self.launch(database)
        let secondService = Self.sweep(second)
        secondService.start()
        await secondService.waitForCompletion()

        #expect(first.reader.reads.count == Self.allPaths.count)
        #expect(second.reader.reads.isEmpty)
        #expect(second.fetcher.fetchCount == 0)
    }

    @Test("start is a no-op while a pass is in flight")
    func startIsANoOpWhileAPassRuns() async throws {
        let database = try AppDatabase.makeEmpty()
        try seedTracks(database, paths: Self.allPaths)
        let fixture = Self.launch(database)

        let service = Self.sweep(fixture)
        service.start()
        service.start()
        await service.waitForCompletion()

        #expect(fixture.reader.reads.count == Self.allPaths.count)
    }

    /// The launch on which the user first adds a library folder refreshes the roots
    /// AFTER the launch pass has already drained an empty library. A service that
    /// latched forever would leave every newly scanned track unprobed until the next
    /// relaunch — the reported "lyrics never fill in by themselves" bug.
    @Test("a pass that has finished re-arms, so tracks scanned later are still swept")
    func startRunsAgainForTracksScannedAfterTheFirstPass() async throws {
        let database = try AppDatabase.makeEmpty()
        let fixture = Self.launch(database)
        let service = Self.sweep(fixture)

        service.start()
        await service.waitForCompletion()
        #expect(fixture.reader.reads.isEmpty)

        try seedTracks(database, paths: Self.allPaths)
        service.start()
        await service.waitForCompletion()

        #expect(fixture.reader.reads.count == Self.allPaths.count)
        try #expect(fixture.cache.load(forKey: Self.withLyrics)?.plainText == "la la la")
        try await #expect(Self.unprobed(database).isEmpty)
    }

    @Test("the pass announces cached documents and stays silent for sentinels")
    func onDidCacheLyricsFiresOnlyForRealDocuments() async throws {
        let database = try AppDatabase.makeEmpty()
        try seedTracks(database, paths: Self.allPaths)
        let fixture = Self.launch(database)
        let signals = SignalCounter()

        let service = Self.sweep(fixture)
        service.onDidCacheLyrics = { signals.increment() }
        service.start()
        await service.waitForCompletion()

        #expect(signals.count == 1)
    }

    // MARK: - Cancellation and resume

    @Test("a cancelled pass keeps its committed rows and the next launch resumes")
    func cancellationResumesFromProbedRows() async throws {
        let database = try AppDatabase.makeEmpty()
        try seedTracks(database, paths: Self.allPaths)
        let fixture = Self.launch(database)
        let gate = ProbeGate()
        let service = Self.sweep(
            fixture,
            provider: GatedLyricsProvider(base: fixture.provider, gate: gate),
            chunkSize: 1
        )

        service.start()
        await gate.waitForFirstArrival()
        service.cancel()
        await gate.open()
        await service.waitForCompletion()

        await #expect(gate.arrivalCount == 1)
        let remaining = try await Self.unprobed(database)
        #expect(remaining.count == Self.allPaths.count - 1)
        #expect(!remaining.contains(Self.withLyrics))

        let resumed = Self.launch(database)
        let resumedService = Self.sweep(resumed)
        resumedService.start()
        await resumedService.waitForCompletion()

        #expect(resumed.reader.reads.count == Self.allPaths.count - 1)
        try await #expect(Self.unprobed(database).isEmpty)
    }

    // MARK: - Sentinel interaction

    @Test("a sentinel does not block a later online resolve from storing real lyrics")
    func sentinelDoesNotBlockOnlineResolve() async throws {
        let database = try AppDatabase.makeEmpty()
        try seedTracks(database, paths: Self.allPaths)
        let fixture = Self.launch(database)
        let service = Self.sweep(fixture)
        service.start()
        await service.waitForCompletion()

        let key = Self.withoutLyrics[0]
        let online = LyricsService(
            embeddedReader: CountingEmbeddedLyricsReader(),
            sidecar: FakeSidecarReader(nil),
            lrclib: MockOnlineLyricsFetcher(returning: OnlineLyricsResult(syncedLyrics: "[00:01.00]net")),
            cache: fixture.cache
        )
        let resolved = try await online.resolveLyrics(
            for: LyricsRequest(trackURL: URL(fileURLWithPath: key)),
            options: .online
        )

        #expect(resolved?.source == .lrclib)
        try #expect(fixture.cache.load(forKey: key)?.source == .lrclib)
    }

    // MARK: - The anti-join

    @Test("the anti-join is bounded, keyset-ordered, and treats sentinels as probed")
    func antiJoinPagesAndSkipsProbedTracks() async throws {
        let database = try AppDatabase.makeEmpty()
        try seedTracks(database, paths: Self.allPaths)
        let repository = TrackRepository(database)

        let firstPage = try await repository.filePathsWithoutLyricsProbe(limit: 2)
        #expect(firstPage.map(\.filePath) == Array(Self.allPaths.prefix(2)))

        let secondPage = try await repository.filePathsWithoutLyricsProbe(after: firstPage.last?.id, limit: 2)
        #expect(secondPage.map(\.filePath) == Array(Self.allPaths.suffix(1)))

        let cache = GRDBLyricsCache(database)
        try cache.markNoLyrics(forKey: Self.allPaths[0])
        try cache.store(Lyrics(lines: [LyricLine(text: "x")], source: .lrcFile), forKey: Self.allPaths[1])

        try await #expect(Self.unprobed(database) == [Self.allPaths[2]])
    }

    @Test("a missing track is never swept")
    func unavailableTracksAreSkipped() async throws {
        let database = try AppDatabase.makeEmpty()
        let repository = TrackRepository(database)
        _ = try repository.insert(TrackRecord(filePath: "/music/gone.flac", availability: .missing))

        try await #expect(Self.unprobed(database).isEmpty)
    }
}
