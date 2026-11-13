// EnrichmentViewModelTests — the @Observable projection mirrors the service.
import Foundation
import Lyrics
import Metadata
import Persistence
import PlayerCoreTestSupport
import Services
import Testing
import ViewModels

@MainActor
@Suite("EnrichmentViewModelTests")
struct EnrichmentViewModelTests {
    @Test("a fresh projection is idle with a zeroed counter")
    func initialStateIsIdle() throws {
        let database = try AppDatabase.makeEmpty()
        let service = makeService(database)
        let viewModel = EnrichmentViewModel(service: service)

        #expect(viewModel.isRunning == false)
        #expect(viewModel.isPaused == false)
        #expect(viewModel.progressFraction == 0)
        #expect(viewModel.progressText == "0 / 0")
        #expect(viewModel.currentTrack == nil)
    }

    @Test("the projection mirrors progress through to completion")
    func mirrorsCompletion() async throws {
        let database = try AppDatabase.makeEmpty()
        let url = try makeTempAudioFile(ext: "mp3")
        _ = try insertTrack(database, TrackRecord(filePath: url.path, availability: .present))
        let service = makeService(database)
        let viewModel = EnrichmentViewModel(service: service)

        viewModel.start()
        await pollUntil { !viewModel.isRunning }

        #expect(viewModel.progressFraction == 1.0)
        #expect(viewModel.progressText == "1 / 1")
        #expect(viewModel.isRunning == false)
        #expect(viewModel.currentTrack == nil)
    }

    @Test("refreshCoverage publishes the reader's counts")
    func refreshPublishesCoverage() async throws {
        let database = try AppDatabase.makeEmpty()
        let counts = EnrichmentCoverageCounts(
            presentTracks: 340,
            tracksWithLyrics: 12,
            tracksProbedNoLyrics: 7,
            tracksMissingCoreMetadata: 58
        )
        let reader = FakeEnrichmentCoverageReader(counts: counts)
        let viewModel = EnrichmentViewModel(service: makeService(database), reader: reader)

        #expect(viewModel.coverage == nil)
        await viewModel.refreshCoverage()

        #expect(viewModel.coverage == counts)
        #expect(reader.countsCallCount == 1)
    }

    @Test("without a reader the projection stays dormant instead of failing")
    func dormantReaderLeavesCoverageNil() async throws {
        let database = try AppDatabase.makeEmpty()
        let viewModel = EnrichmentViewModel(service: makeService(database))

        await viewModel.refreshCoverage()

        #expect(viewModel.coverage == nil)
        #expect(viewModel.idleSummary(completed: 0) == .upToDate)
    }

    @Test("finishing a pass re-reads coverage without a second observer")
    func finishingAPassRefreshesCoverage() async throws {
        let database = try AppDatabase.makeEmpty()
        let url = try makeTempAudioFile(ext: "mp3")
        _ = try insertTrack(database, TrackRecord(filePath: url.path, availability: .present))
        let reader = FakeEnrichmentCoverageReader(counts: EnrichmentCoverageCounts(presentTracks: 1))
        let viewModel = EnrichmentViewModel(service: makeService(database), reader: reader)

        await viewModel.refreshCoverage()
        #expect(reader.countsCallCount == 1)

        viewModel.start()
        await pollUntil { !viewModel.isRunning }
        await pollUntil { reader.countsCallCount == 2 }

        #expect(reader.countsCallCount == 2)
    }

    @Test("a library with nothing enriched reports its coverage, never “up to date”")
    func zeroEnrichedNeverReportsUpToDate() async throws {
        let database = try AppDatabase.makeEmpty()
        let counts = EnrichmentCoverageCounts(presentTracks: 340, tracksMissingCoreMetadata: 340)
        let viewModel = EnrichmentViewModel(
            service: makeService(database),
            reader: FakeEnrichmentCoverageReader(counts: counts)
        )

        await viewModel.refreshCoverage()

        #expect(viewModel.idleSummary(completed: 0) == .coverage(counts))
        #expect(viewModel.idleSummary(completed: 0) != .upToDate)
    }

    @Test("an empty library reports all-zero coverage rather than claiming to be up to date")
    func emptyLibraryReportsZeroedCoverage() async throws {
        let database = try AppDatabase.makeEmpty()
        let viewModel = EnrichmentViewModel(
            service: makeService(database),
            reader: FakeEnrichmentCoverageReader(counts: .empty)
        )

        await viewModel.refreshCoverage()

        #expect(viewModel.coverage == .empty)
        #expect(viewModel.idleSummary(completed: 0) == .coverage(.empty))
    }

    @Test("a finished pass still reports its own tally ahead of coverage")
    func completedPassOutranksCoverage() async throws {
        let database = try AppDatabase.makeEmpty()
        let viewModel = EnrichmentViewModel(
            service: makeService(database),
            reader: FakeEnrichmentCoverageReader(counts: EnrichmentCoverageCounts(presentTracks: 340))
        )

        await viewModel.refreshCoverage()

        #expect(viewModel.idleSummary(completed: 9) == .enriched(count: 9))
    }

    @Test("a failing read keeps the counts already on screen")
    func failedReadKeepsPreviousCoverage() async throws {
        let database = try AppDatabase.makeEmpty()
        let counts = EnrichmentCoverageCounts(presentTracks: 12, tracksWithLyrics: 3)
        let reader = FakeEnrichmentCoverageReader(counts: counts)
        let viewModel = EnrichmentViewModel(service: makeService(database), reader: reader)

        await viewModel.refreshCoverage()
        reader.setError(CocoaError(.fileReadUnknown))
        await viewModel.refreshCoverage()

        #expect(viewModel.coverage == counts)
    }

    private func makeService(_ database: AppDatabase) -> EnrichmentService {
        EnrichmentService(
            database: database,
            metadataFetcher: StubMetadataFetcher(returning: nil),
            metadataWriter: FakeMetadataWriter(),
            lyricsProvider: FakeLyricsProvider()
        )
    }
}
