// LoudnessScanViewModelTests — the projection mirrors the pass, reports library
// coverage independently of it, and never starts anything on its own.
//
// The coverage cases run over a library the service never touched, so a regression
// that wired `analyzedFraction` to `service.progress` would still fail them. The
// coverage/stale identity is asserted against the repository's own
// `staleCandidateCount`, because those two numbers are restated SQL clauses that
// must partition the same population — a drift between them is exactly the bug
// neither query can see alone.
import Foundation
import GRDB
import Persistence
import Services
import Testing
import ViewModels

@MainActor
@Suite("LoudnessScanViewModelTests")
struct LoudnessScanViewModelTests {
    @Test("a fresh projection is idle, with a zeroed counter and no pass started")
    func initialStateIsIdle() throws {
        let database = try AppDatabase.makeEmpty()
        let service = FakeLoudnessScanService()
        let viewModel = LoudnessScanViewModel(service: service, database: database)

        #expect(viewModel.isRunning == false)
        #expect(viewModel.isPaused == false)
        #expect(viewModel.progressFraction == 0)
        #expect(viewModel.progressText == "0 / 0")
        #expect(viewModel.currentTrack == nil)
        #expect(viewModel.failedCount == 0)
        #expect(service.startCount == 0)
        #expect(service.fullReanalysisCount == 0)
    }

    @Test("the projection mirrors running, paused and progress state")
    func mirrorsRunningPausedAndProgress() throws {
        let database = try AppDatabase.makeEmpty()
        let service = FakeLoudnessScanService()
        let viewModel = LoudnessScanViewModel(service: service, database: database)

        viewModel.start()
        #expect(viewModel.isRunning)

        service.simulateProgress(completed: 3, total: 10, currentTrack: "Third", failedCount: 1)
        #expect(viewModel.progressFraction == 0.3)
        #expect(viewModel.progressText == "3 / 10")
        #expect(viewModel.currentTrack == "Third")
        #expect(viewModel.failedCount == 1)

        viewModel.pause()
        #expect(viewModel.isPaused)
        viewModel.resume()
        #expect(viewModel.isPaused == false)
        viewModel.stop()
        #expect(viewModel.isRunning == false)
    }

    /// `progress.total` is a start-of-pass snapshot, so a library scan landing
    /// mid-pass lets `completed` overshoot it and a raw division would drive a
    /// determinate bar past its end.
    @Test("progressFraction is clamped when completed overshoots total")
    func progressFractionIsClamped() throws {
        let database = try AppDatabase.makeEmpty()
        let service = FakeLoudnessScanService()
        let viewModel = LoudnessScanViewModel(service: service, database: database)

        service.simulateProgress(completed: 14, total: 10)

        #expect(viewModel.progressFraction == 1)
        #expect(viewModel.progressText == "14 / 10")
    }

    @Test("rescanAll forwards to the destructive pass, not the incremental one")
    func rescanAllForwardsToTheDestructivePass() throws {
        let database = try AppDatabase.makeEmpty()
        let service = FakeLoudnessScanService()
        let viewModel = LoudnessScanViewModel(service: service, database: database)

        viewModel.rescanAll()

        #expect(service.fullReanalysisCount == 1)
        #expect(service.startCount == 0)
    }
}

// MARK: - The selection action

@MainActor
@Suite("LoudnessSelectionAnalysisTests")
struct LoudnessSelectionAnalysisTests {
    /// The acceptance criterion: the action invalidates EXACTLY the selection —
    /// de-duplicated, in the order the listener sees — and then runs one pass.
    @Test("analyze invalidates exactly the selection, then starts one pass")
    func analyzeInvalidatesExactlyTheSelection() async throws {
        let database = try AppDatabase.makeEmpty()
        let service = FakeLoudnessScanService()
        let invalidator = RecordingLoudnessInvalidator()
        let viewModel = LoudnessScanViewModel(
            service: service,
            database: database,
            invalidator: invalidator
        )

        await viewModel.analyze(trackIds: [7, 3, 7, 11])

        let batches = await invalidator.batches
        #expect(batches == [[7, 3, 11]])
        #expect(service.startCount == 1)
        #expect(service.fullReanalysisCount == 0)
    }

    /// `PlaybackCoordinator` passes `track.trackID ?? 0`, so `0` is the "not a
    /// library track" sentinel. `track.id` is a rowid alias starting at 1, so it
    /// can never name a row and must not reach a `DELETE … WHERE trackId IN (…)`.
    @Test("analyze drops the non-library sentinel before the seam")
    func analyzeDropsTheNonLibrarySentinel() async throws {
        let database = try AppDatabase.makeEmpty()
        let service = FakeLoudnessScanService()
        let invalidator = RecordingLoudnessInvalidator()
        let viewModel = LoudnessScanViewModel(
            service: service,
            database: database,
            invalidator: invalidator
        )

        await viewModel.analyze(trackIds: [0, 5, -1])

        let batches = await invalidator.batches
        #expect(batches == [[5]])
        #expect(service.startCount == 1)
    }

    @Test("analyze on an empty selection touches nothing")
    func analyzeOnAnEmptySelectionTouchesNothing() async throws {
        let database = try AppDatabase.makeEmpty()
        let service = FakeLoudnessScanService()
        let invalidator = RecordingLoudnessInvalidator()
        let viewModel = LoudnessScanViewModel(
            service: service,
            database: database,
            invalidator: invalidator
        )

        await viewModel.analyze(trackIds: [0])

        let batches = await invalidator.batches
        #expect(batches.isEmpty)
        #expect(service.startCount == 0)
    }
}

// MARK: - Coverage

@MainActor
@Suite("LoudnessCoverageTests")
struct LoudnessCoverageTests {
    @Test("coverage on a half-measured library reads 0.5")
    func coverageOnAHalfMeasuredLibrary() async throws {
        let database = try LoudnessCoverageFixture.makeLibrary(presentCount: 10, measuredCount: 5)
        let viewModel = LoudnessScanViewModel(service: FakeLoudnessScanService(), database: database)

        await viewModel.refreshCoverage()

        #expect(viewModel.analyzedFraction == 0.5)
        #expect(viewModel.analyzedTrackCount == 5)
        #expect(viewModel.analyzableTrackCount == 10)
    }

    /// `0` means two different things — "nothing is measured" and "the read has
    /// not landed yet" — and a caller that cannot tell them apart greys out an
    /// action on a fully measured library.
    @Test("hasMeasuredCoverage is false until a coverage read lands")
    func hasMeasuredCoverageIsFalseUntilAReadLands() async throws {
        let database = try LoudnessCoverageFixture.makeLibrary(presentCount: 4, measuredCount: 4)
        let viewModel = LoudnessScanViewModel(service: FakeLoudnessScanService(), database: database)

        await pollUntil { viewModel.hasMeasuredCoverage }

        #expect(viewModel.hasMeasuredCoverage)
        #expect(viewModel.analyzedFraction == 1)
    }

    @Test("an empty library measures successfully as zero")
    func anEmptyLibraryMeasuresAsZero() async throws {
        let database = try AppDatabase.makeEmpty()
        let viewModel = LoudnessScanViewModel(service: FakeLoudnessScanService(), database: database)

        await viewModel.refreshCoverage()

        #expect(viewModel.hasMeasuredCoverage)
        #expect(viewModel.analyzedFraction == 0)
        #expect(viewModel.analyzableTrackCount == 0)
    }

    @Test("coverage excludes missing tracks and fingerprint-stale rows")
    func coverageExcludesMissingAndStale() async throws {
        let database = try LoudnessCoverageFixture.makeLibrary(
            presentCount: 4,
            measuredCount: 2,
            missingCount: 3
        )
        try LoudnessCoverageFixture.staleFingerprint(database, trackId: 1)
        let viewModel = LoudnessScanViewModel(service: FakeLoudnessScanService(), database: database)

        await viewModel.refreshCoverage()

        #expect(viewModel.analyzableTrackCount == 4)
        #expect(viewModel.analyzedTrackCount == 1)
        #expect(viewModel.analyzedFraction == 0.25)
    }

    /// The identity the read-out rests on: the coverage clause is the positive
    /// twin of the repository's staleness clause, so what one calls "not
    /// analysed" the other must call "a stale candidate". Both are restated SQL
    /// and neither can detect a drift alone.
    @Test("coverage.stale agrees with the repository's stale candidate count")
    func coverageStaleAgreesWithTheRepository() async throws {
        let database = try LoudnessCoverageFixture.makeLibrary(
            presentCount: 6,
            measuredCount: 4,
            missingCount: 2
        )
        try LoudnessCoverageFixture.staleFingerprint(database, trackId: 2)
        let version = LoudnessScanService.analysisVersion

        let coverage = try await database.writer.read { db in
            try TrackLoudnessCoverageReader.libraryCoverage(db, analysisVersion: version)
        }
        let stale = try await TrackLoudnessRepository(database)
            .staleCandidateCount(analysisVersion: version)

        #expect(coverage.total == 6)
        #expect(coverage.analyzed == 3)
        #expect(coverage.stale == stale)
    }

    /// A fingerprint-stale row is NOT analysed, but playback can still fall back
    /// on it — the resolver compares cue bounds, not the fingerprint. The two
    /// readings must therefore disagree here, which is why both exist.
    @Test("measured counts a stale row that analyzed does not")
    func measuredCountsAStaleRowAnalyzedDoesNot() async throws {
        let database = try LoudnessCoverageFixture.makeLibrary(presentCount: 3, measuredCount: 3)
        try LoudnessCoverageFixture.staleFingerprint(database, trackId: 1)
        let version = LoudnessScanService.analysisVersion

        let coverage = try await database.writer.read { db in
            try TrackLoudnessCoverageReader.libraryCoverage(db, analysisVersion: version)
        }

        #expect(coverage.analyzed == 2)
        #expect(coverage.measured == 3)
        #expect(coverage.total == 3)
    }
}
