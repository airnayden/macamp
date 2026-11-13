// EnrichmentLaneTests — the two-lane page driver.
//
// The property under test is LANE PURITY: everything that queues behind the one
// shared MusicBrainz limiter (metadata lookup, composer follow-up, info prefetch)
// must run strictly one-at-a-time, while the LRCLIB lyrics fetch must overlap.
// A shared ``LaneActivityProbe`` sees every rate-limited call from both fakes, so
// `maxObserved == 1` is the serialization proof; ``SlowLyricsProvider``'s own peak
// counter is the overlap proof.
import Foundation
import GRDB
import Lyrics
import Metadata
import Persistence
import PlayerCoreTestSupport
import Services
import Testing

@MainActor
@Suite("EnrichmentLaneTests")
struct EnrichmentLaneTests {
    @Test("a metadata-complete track performs zero MusicBrainz lookups")
    func metadataCompleteSkipsMusicBrainz() async throws {
        let database = try AppDatabase.makeEmpty()
        try seedComplete(database, count: 1)
        let fetcher = StubMetadataFetcher(returning: MetadataLookupResult(title: "Unused"))
        let service = makeService(database, fetcher: fetcher, info: FakeInfoService(cachesEverything: true))

        service.start()
        await pollUntil { !service.isRunning }

        #expect(fetcher.lookupCount == 0)
        #expect(fetcher.composerLookupCount == 0)
    }

    @Test("a metadata-complete, info-cached track performs zero rate-limited work")
    func parallelLanePurity() async throws {
        let database = try AppDatabase.makeEmpty()
        try seedComplete(database, count: 1)
        let probe = LaneActivityProbe()
        let info = FakeInfoService(cachesEverything: true, onPrefetchActivity: probe.record)
        let fetcher = StubMetadataFetcher(returning: nil, onActivity: probe.record)
        let lyrics = FakeLyricsProvider()
        let service = makeService(database, fetcher: fetcher, info: info, lyrics: lyrics)

        service.start()
        await pollUntil { !service.isRunning }

        #expect(info.prefetchCount == 0)
        #expect(fetcher.lookupCount == 0)
        #expect(probe.maxObserved == 0)
        #expect(lyrics.requests.count == 1)
        #expect(service.progress.completed == 1)
    }

    @Test("an info-uncached track routes through the serial lane")
    func uncachedInfoRoutesSerial() async throws {
        let database = try AppDatabase.makeEmpty()
        try seedComplete(database, count: 1)
        let info = FakeInfoService()
        let fetcher = StubMetadataFetcher(returning: nil)
        let service = makeService(database, fetcher: fetcher, info: info)

        service.start()
        await pollUntil { !service.isRunning }

        #expect(fetcher.lookupCount == 0)
        #expect(info.prefetchedTitles == ["Complete 0"])
        #expect(info.prefetchedArtists == ["Artist 0"])
    }

    @Test("lyrics overlap while every rate-limited call stays serialized")
    func lanesOverlapIndependently() async throws {
        let database = try AppDatabase.makeEmpty()
        try seedComplete(database, count: 6)
        try seedIncomplete(database, count: 2)
        let probe = LaneActivityProbe()
        let info = FakeInfoService(
            cachedArtists: completeArtists(count: 6),
            latency: .milliseconds(20),
            onPrefetchActivity: probe.record
        )
        let fetcher = StubMetadataFetcher(
            returning: MetadataLookupResult(title: "Filled", artist: "Filled Artist"),
            latency: .milliseconds(20),
            onActivity: probe.record
        )
        let lyrics = SlowLyricsProvider(latency: .milliseconds(80))
        let service = makeService(database, fetcher: fetcher, info: info, lyrics: lyrics)

        service.start()
        await pollUntil(timeout: .seconds(20)) { !service.isRunning }

        #expect(lyrics.maxObservedConcurrency >= 2)
        #expect(lyrics.maxObservedConcurrency <= EnrichmentService.lyricsLaneConcurrency)
        #expect(probe.maxObserved == 1)
        #expect(fetcher.lookupCount == 2)
        #expect(service.progress.completed == 8)
        #expect(service.progress.completed == service.progress.total)
    }

    @Test("pause blocks new lyrics-lane starts until resume")
    func pauseGatesParallelLane() async throws {
        let database = try AppDatabase.makeEmpty()
        try seedComplete(database, count: 16)
        let lyrics = SlowLyricsProvider(latency: .milliseconds(60))
        let service = makeService(
            database,
            fetcher: StubMetadataFetcher(returning: nil),
            info: FakeInfoService(cachesEverything: true),
            lyrics: lyrics
        )

        service.start()
        await pollUntil { service.progress.completed >= 1 }
        service.pause()
        try? await Task.sleep(for: .milliseconds(300))
        let settled = service.progress.completed
        #expect(settled < 16)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(service.progress.completed == settled)

        service.resume()
        await pollUntil(timeout: .seconds(20)) { !service.isRunning }
        #expect(service.progress.completed == 16)
    }

    @Test("pause blocks new serial-lane starts until resume")
    func pauseGatesSerialLane() async throws {
        let database = try AppDatabase.makeEmpty()
        try seedIncomplete(database, count: 4)
        let fetcher = StubMetadataFetcher(
            returning: MetadataLookupResult(title: "Filled"),
            latency: .milliseconds(80)
        )
        let service = makeService(database, fetcher: fetcher, info: FakeInfoService(cachesEverything: true))

        service.start()
        await pollUntil { fetcher.lookupCount >= 1 }
        service.pause()
        try? await Task.sleep(for: .milliseconds(300))
        let settled = fetcher.lookupCount
        #expect(settled < 4)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(fetcher.lookupCount == settled)

        service.resume()
        await pollUntil(timeout: .seconds(20)) { !service.isRunning }
        #expect(service.progress.completed == 4)
    }

    @Test("a throwing lyrics fetch neither stalls the lane nor double-counts")
    func throwingLyricsDoesNotStall() async throws {
        let database = try AppDatabase.makeEmpty()
        let paths = try seedComplete(database, count: 4)
        let lyrics = SlowLyricsProvider(latency: .milliseconds(20), failing: [paths[2]])
        let service = makeService(
            database,
            fetcher: StubMetadataFetcher(returning: nil),
            info: FakeInfoService(cachesEverything: true),
            lyrics: lyrics
        )

        service.start()
        await pollUntil(timeout: .seconds(20)) { !service.isRunning }

        #expect(lyrics.requests.count == 4)
        #expect(service.progress.completed == 4)
        #expect(service.progress.completed == service.progress.total)
    }

    @Test("stop() mid-page leaves progress bounded and no unfinished commit")
    func cancellationStaysBounded() async throws {
        let database = try AppDatabase.makeEmpty()
        try seedIncomplete(database, count: 6)
        let fetcher = BlockingMetadataFetcher(returning: MetadataLookupResult(title: "Filled"), blockAfter: 1)
        let service = makeService(database, fetcher: fetcher, info: FakeInfoService(cachesEverything: true))

        service.start()
        await pollUntil { service.progress.completed >= 1 }
        service.stop()
        await pollUntil { !service.isRunning }

        #expect(service.progress.completed <= service.progress.total)
        #expect(service.currentTrack == nil)
        // A row can only carry the filled title if its commit ran to completion,
        // so a fill without a matching lookup would mean a torn write.
        let filled = try await database.writer.read { db in
            try TrackRecord.filter(TrackRecord.Columns.title == "Filled").fetchCount(db)
        }
        #expect(filled <= fetcher.lookupCount)
    }
}

// MARK: - Fixtures

private extension EnrichmentLaneTests {
    func makeService(
        _ database: AppDatabase,
        fetcher: any OnlineMetadataFetching,
        info: FakeInfoService,
        lyrics: any LyricsProviding = FakeLyricsProvider()
    ) -> EnrichmentService {
        EnrichmentService(
            database: database,
            metadataFetcher: fetcher,
            metadataWriter: FakeMetadataWriter(),
            lyricsProvider: lyrics,
            infoService: info
        )
    }

    func completeArtists(count: Int) -> Set<String> {
        Set((0 ..< count).map { "Artist \($0)" })
    }

    /// Inserts `count` metadata-complete tracks and returns their file paths.
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

    /// Inserts `count` tracks missing every fill-missing field, so each one needs
    /// the serial MusicBrainz lane.
    @discardableResult
    func seedIncomplete(_ database: AppDatabase, count: Int) throws -> [String] {
        try (0 ..< count).map { index in
            let path = "/fixtures/incomplete-\(index).mp3"
            try insertTrack(database, TrackRecord(filePath: path, availability: .present))
            return path
        }
    }
}
