// EnrichmentServiceTests — the background enrichment engine driven through an
// in-memory database and the network-free Stub/Blocking fetchers + fakes.
import Foundation
import Lyrics
import Metadata
import Persistence
import PlayerCoreTestSupport
import Services
import Testing

@MainActor
@Suite("EnrichmentServiceTests")
struct EnrichmentServiceTests {
    @Test("fills missing fields from a lookup and writes the writable file")
    func fillsMissingFields() async throws {
        let database = try AppDatabase.makeEmpty()
        let url = try makeTempAudioFile(ext: "mp3")
        let track = try insertTrack(database, TrackRecord(filePath: url.path, availability: .present))
        let id = try #require(track.id)
        let result = MetadataLookupResult(
            title: "Come Together",
            artist: "The Beatles",
            album: "Abbey Road",
            year: 1969,
            trackNumber: 1
        )
        let writer = FakeMetadataWriter()
        let lyrics = FakeLyricsProvider()
        let service = makeService(database, StubMetadataFetcher(returning: result), writer, lyrics)

        service.start()
        await pollUntil { !service.isRunning }

        let updated = try #require(try fetchTrack(database, id: id))
        #expect(updated.title == "Come Together")
        #expect(updated.artistName == "The Beatles")
        #expect(updated.albumTitle == "Abbey Road")
        #expect(updated.year == 1969)
        #expect(updated.trackNumber == 1)
        #expect(updated.sortTitle != nil)
        let call = try #require(writer.calls.first)
        #expect(call.metadata.title == "Come Together")
        #expect(call.metadata.artist == "The Beatles")
        #expect(lyrics.requests.count == 1)
    }

    @Test("never overwrites a field that already has a value")
    func doesNotOverwrite() async throws {
        let database = try AppDatabase.makeEmpty()
        let url = try makeTempAudioFile(ext: "mp3")
        let track = try insertTrack(
            database,
            TrackRecord(filePath: url.path, title: "Existing Title", availability: .present)
        )
        let id = try #require(track.id)
        let result = MetadataLookupResult(title: "New Title", artist: "New Artist")
        let writer = FakeMetadataWriter()
        let service = makeService(database, StubMetadataFetcher(returning: result), writer, FakeLyricsProvider())

        service.start()
        await pollUntil { !service.isRunning }

        let updated = try #require(try fetchTrack(database, id: id))
        #expect(updated.title == "Existing Title")
        #expect(updated.artistName == "New Artist")
        let call = try #require(writer.calls.first)
        #expect(call.metadata.title == nil)
        #expect(call.metadata.artist == "New Artist")
    }

    @Test("skips a track whose file is not present")
    func skipsNonPresent() async throws {
        let database = try AppDatabase.makeEmpty()
        let track = try insertTrack(
            database,
            TrackRecord(filePath: "/missing/x.mp3", availability: .missing)
        )
        let id = try #require(track.id)
        let fetcher = StubMetadataFetcher(returning: MetadataLookupResult(title: "X"))
        let writer = FakeMetadataWriter()
        let lyrics = FakeLyricsProvider()
        let service = makeService(database, fetcher, writer, lyrics)

        service.start()
        await pollUntil { !service.isRunning }

        let after = try #require(try fetchTrack(database, id: id))
        #expect(after.title == nil)
        #expect(fetcher.lookupCount == 0)
        #expect(writer.calls.isEmpty)
        #expect(lyrics.requests.isEmpty)
        #expect(service.progress.total == 0)
    }

    @Test("enriches the DB but skips the file write for a non-writable format")
    func skipsWriteForWav() async throws {
        let database = try AppDatabase.makeEmpty()
        let url = try makeTempAudioFile(ext: "wav")
        let track = try insertTrack(database, TrackRecord(filePath: url.path, availability: .present))
        let id = try #require(track.id)
        let result = MetadataLookupResult(title: "Title", artist: "Artist")
        let writer = FakeMetadataWriter()
        let service = makeService(database, StubMetadataFetcher(returning: result), writer, FakeLyricsProvider())

        service.start()
        await pollUntil { !service.isRunning }

        let updated = try #require(try fetchTrack(database, id: id))
        #expect(updated.title == "Title")
        #expect(writer.calls.isEmpty)
    }

    @Test("fills a missing composer via the work-relationship follow-up")
    func fillsComposer() async throws {
        let database = try AppDatabase.makeEmpty()
        let url = try makeTempAudioFile(ext: "flac")
        let track = try insertTrack(database, TrackRecord(filePath: url.path, availability: .present))
        let id = try #require(track.id)
        let result = MetadataLookupResult(title: "Song", recordingID: "mbid-123")
        let fetcher = StubMetadataFetcher(returning: result, composer: "Beethoven")
        let service = makeService(database, fetcher, FakeMetadataWriter(), FakeLyricsProvider())

        service.start()
        await pollUntil { !service.isRunning }

        let updated = try #require(try fetchTrack(database, id: id))
        #expect(updated.composer == "Beethoven")
        #expect(fetcher.composerLookupCount == 1)
    }

    @Test("stop() halts the pass but keeps already-committed rows")
    func cancellationKeepsCommitted() async throws {
        let database = try AppDatabase.makeEmpty()
        let url1 = try makeTempAudioFile(ext: "mp3")
        let url2 = try makeTempAudioFile(ext: "mp3")
        let first = try insertTrack(database, TrackRecord(filePath: url1.path, availability: .present))
        _ = try insertTrack(database, TrackRecord(filePath: url2.path, availability: .present))
        let id1 = try #require(first.id)
        let fetcher = BlockingMetadataFetcher(returning: MetadataLookupResult(title: "Filled"), blockAfter: 1)
        let service = makeService(database, fetcher, FakeMetadataWriter(), FakeLyricsProvider())

        service.start()
        await pollUntil { service.progress.completed >= 1 }
        service.stop()
        await pollUntil { !service.isRunning }

        let committed = try #require(try fetchTrack(database, id: id1))
        #expect(committed.title == "Filled")
        #expect(service.isRunning == false)
    }

    @Test("pause/resume/stop drive the running state")
    func controlSurface() async throws {
        let database = try AppDatabase.makeEmpty()
        let url1 = try makeTempAudioFile(ext: "mp3")
        let url2 = try makeTempAudioFile(ext: "mp3")
        _ = try insertTrack(database, TrackRecord(filePath: url1.path, availability: .present))
        _ = try insertTrack(database, TrackRecord(filePath: url2.path, availability: .present))
        let fetcher = BlockingMetadataFetcher(returning: MetadataLookupResult(title: "X"), blockAfter: 1)
        let service = makeService(database, fetcher, FakeMetadataWriter(), FakeLyricsProvider())

        #expect(service.isRunning == false)
        service.start()
        #expect(service.isRunning == true)
        await pollUntil { service.progress.completed >= 1 }
        service.pause()
        #expect(service.isPaused == true)
        service.resume()
        #expect(service.isPaused == false)
        service.stop()
        #expect(service.isRunning == false)
        #expect(service.isPaused == false)
    }

    @Test("stop() before start() is a safe no-op")
    func stopBeforeStart() throws {
        let database = try AppDatabase.makeEmpty()
        let service = makeService(
            database,
            StubMetadataFetcher(returning: nil),
            FakeMetadataWriter(),
            FakeLyricsProvider()
        )
        service.stop()
        #expect(service.isRunning == false)
    }

    private func makeService(
        _ database: AppDatabase,
        _ fetcher: any OnlineMetadataFetching,
        _ writer: FakeMetadataWriter,
        _ lyrics: FakeLyricsProvider
    ) -> EnrichmentService {
        EnrichmentService(
            database: database,
            metadataFetcher: fetcher,
            metadataWriter: writer,
            lyricsProvider: lyrics
        )
    }
}
