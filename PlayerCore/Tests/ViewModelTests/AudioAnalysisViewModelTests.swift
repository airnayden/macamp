// AudioAnalysisViewModelTests — the @Observable projection mirrors the pass, and
// reports library coverage independently of it.
//
// The two halves are deliberately separate assertions. `progressFraction`
// describes the CURRENT pass and comes from the service; `analyzedFraction`
// describes the LIBRARY and comes from its own bounded `COUNT(*)` pair. A
// regression that wired the second to `service.progress` would still pass a
// mid-pass progress test, so the coverage cases run over a library the service
// never touched.
import Foundation
import GRDB
import Persistence
import PlayerCoreTestSupport
import Services
import Testing
import ViewModels

@MainActor
@Suite("AudioAnalysisViewModelTests")
struct AudioAnalysisViewModelTests {
    @Test("a fresh projection is idle with a zeroed counter")
    func initialStateIsIdle() throws {
        let database = try AppDatabase.makeEmpty()
        let viewModel = AudioAnalysisViewModel(service: FakeAudioAnalysisService(), database: database)

        #expect(viewModel.isRunning == false)
        #expect(viewModel.isPaused == false)
        #expect(viewModel.progressFraction == 0)
        #expect(viewModel.progressText == "0 / 0")
        #expect(viewModel.currentTrack == nil)
        #expect(viewModel.failedCount == 0)
    }

    @Test("the projection mirrors running, paused and progress state")
    func mirrorsRunningPausedAndProgress() throws {
        let database = try AppDatabase.makeEmpty()
        let service = FakeAudioAnalysisService()
        let viewModel = AudioAnalysisViewModel(service: service, database: database)

        viewModel.start()
        #expect(viewModel.isRunning)
        #expect(viewModel.isPaused == false)

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
        #expect(viewModel.currentTrack == nil)
    }

    /// `progress.total` is a snapshot taken once at pass start, so a library scan
    /// landing mid-pass lets `completed` overshoot it. A raw division would drive
    /// a determinate bar past its end.
    @Test("progressFraction is clamped when completed overshoots total")
    func progressFractionIsClampedWhenCompletedOvershootsTotal() throws {
        let database = try AppDatabase.makeEmpty()
        let service = FakeAudioAnalysisService()
        let viewModel = AudioAnalysisViewModel(service: service, database: database)

        service.simulateProgress(completed: 14, total: 10)

        #expect(viewModel.progressFraction == 1)
        #expect(viewModel.progressText == "14 / 10")
    }

    @Test("every control call forwards to the service exactly once")
    func controlCallsForwardToTheService() throws {
        let database = try AppDatabase.makeEmpty()
        let service = FakeAudioAnalysisService()
        let viewModel = AudioAnalysisViewModel(service: service, database: database)

        viewModel.start()
        viewModel.pause()
        viewModel.resume()
        viewModel.stop()

        #expect(service.startCount == 1)
        #expect(service.pauseCount == 1)
        #expect(service.resumeCount == 1)
        #expect(service.stopCount == 1)
    }

    /// The plan's happy-path QA: ten present tracks, five analysed.
    @Test("analyzedFraction on a half-analyzed library reads 0.5")
    func analyzedFractionOnAHalfAnalyzedLibraryIsAHalf() async throws {
        let database = try AnalysisCoverageFixture.makeLibrary(presentCount: 10, analyzedCount: 5)
        let viewModel = AudioAnalysisViewModel(service: FakeAudioAnalysisService(), database: database)

        await viewModel.refreshAnalyzedFraction()

        #expect(viewModel.analyzedFraction == 0.5)
        #expect(viewModel.analyzedTrackCount == 5)
        #expect(viewModel.analyzableTrackCount == 10)
    }

    /// An empty library divides by nothing — the copy must read "0%", not crash
    /// or show `NaN`.
    @Test("analyzedFraction is zero on an empty library")
    func analyzedFractionIsZeroOnAnEmptyLibrary() async throws {
        let database = try AppDatabase.makeEmpty()
        let viewModel = AudioAnalysisViewModel(service: FakeAudioAnalysisService(), database: database)

        await viewModel.refreshAnalyzedFraction()

        #expect(viewModel.analyzedFraction == 0)
        #expect(viewModel.analyzableTrackCount == 0)
    }

    /// A `missing` track is outside the population the pass walks, so it must not
    /// dilute the denominator; a row whose fingerprint no longer matches the file
    /// describes bytes that are gone, so it must not inflate the numerator.
    @Test("analyzedFraction excludes missing tracks and stale analysis rows")
    func analyzedFractionExcludesMissingTracksAndStaleRows() async throws {
        let database = try AnalysisCoverageFixture.makeLibrary(
            presentCount: 4,
            analyzedCount: 2,
            missingCount: 3
        )
        try AnalysisCoverageFixture.staleFingerprint(database, trackId: 1)
        let viewModel = AudioAnalysisViewModel(service: FakeAudioAnalysisService(), database: database)

        await viewModel.refreshAnalyzedFraction()

        #expect(viewModel.analyzableTrackCount == 4)
        #expect(viewModel.analyzedTrackCount == 1)
        #expect(viewModel.analyzedFraction == 0.25)
    }

    /// Finishing a pass is the one moment coverage is guaranteed to have moved,
    /// so the projection re-reads it without the shell having to poll.
    @Test("analyzedFraction refreshes when a pass finishes")
    func analyzedFractionRefreshesWhenAPassFinishes() async throws {
        let database = try AnalysisCoverageFixture.makeLibrary(presentCount: 4, analyzedCount: 0)
        let service = FakeAudioAnalysisService()
        let viewModel = AudioAnalysisViewModel(service: service, database: database)
        await viewModel.refreshAnalyzedFraction()
        #expect(viewModel.analyzedFraction == 0)

        viewModel.start()
        try AnalysisCoverageFixture.analyse(database, trackIds: [1, 2, 3, 4])
        service.simulateFinish()

        await pollUntil { viewModel.analyzedFraction == 1 }
        #expect(viewModel.analyzedFraction == 1)
        #expect(viewModel.analyzedTrackCount == 4)
    }

    /// The gate bug, at its source. `analyzedFraction` is `0` in two completely
    /// different situations — "nothing is analysed" and "the read has not landed
    /// yet" — and a caller that cannot tell them apart greys out an action on a
    /// fully analysed library. `hasMeasuredCoverage` is the discriminator.
    @Test("hasMeasuredCoverage is false until a coverage read lands")
    func hasMeasuredCoverageIsFalseUntilACoverageReadLands() async throws {
        let database = try AnalysisCoverageFixture.makeLibrary(presentCount: 4, analyzedCount: 4)
        let viewModel = AudioAnalysisViewModel(service: FakeAudioAnalysisService(), database: database)

        await pollUntil { viewModel.hasMeasuredCoverage }
        #expect(viewModel.hasMeasuredCoverage)
        #expect(viewModel.analyzedFraction == 1)
    }

    /// The refresh `init` schedules is what makes a menu opened seconds after
    /// launch see the truth without anyone visiting the Intelligence pane.
    @Test("constructing the projection reads coverage without an explicit refresh")
    func constructingTheProjectionReadsCoverage() async throws {
        let database = try AnalysisCoverageFixture.makeLibrary(presentCount: 4, analyzedCount: 3)
        let viewModel = AudioAnalysisViewModel(service: FakeAudioAnalysisService(), database: database)

        await pollUntil { viewModel.hasMeasuredCoverage }
        #expect(viewModel.analyzedFraction == 0.75)
        #expect(viewModel.analyzedTrackCount == 3)
    }

    /// An EMPTY library measures successfully — `0 of 0` is a real answer, not an
    /// absent one — so the flag must not be confused with "coverage is non-zero".
    @Test("hasMeasuredCoverage becomes true on an empty library too")
    func hasMeasuredCoverageBecomesTrueOnAnEmptyLibrary() async throws {
        let database = try AppDatabase.makeEmpty()
        let viewModel = AudioAnalysisViewModel(service: FakeAudioAnalysisService(), database: database)

        await viewModel.refreshAnalyzedFraction()

        #expect(viewModel.hasMeasuredCoverage)
        #expect(viewModel.analyzedFraction == 0)
    }

    @Test("reanalyzeAll forwards to the destructive pass, not the incremental one")
    func reanalyzeAllForwardsToTheDestructivePass() throws {
        let database = try AppDatabase.makeEmpty()
        let service = FakeAudioAnalysisService()
        let viewModel = AudioAnalysisViewModel(service: service, database: database)

        viewModel.reanalyzeAll()

        #expect(service.fullReanalysisCount == 1)
        #expect(service.startCount == 0)
        #expect(viewModel.isRunning)
    }
}

// MARK: - Fixture

/// A library seeded straight through `Persistence`, with no analysis service
/// involved — so a coverage assertion cannot accidentally be satisfied by the
/// pass's own progress bookkeeping.
private enum AnalysisCoverageFixture {
    static let fileSize: Int64 = 2048
    static let mtime = 42.0

    /// `presentCount` present tracks (ids `1...presentCount`), the first
    /// `analyzedCount` of them carrying a current analysis row, plus
    /// `missingCount` unavailable tracks that must never enter the denominator.
    static func makeLibrary(
        presentCount: Int,
        analyzedCount: Int,
        missingCount: Int = 0
    ) throws -> AppDatabase {
        let database = try AppDatabase.makeEmpty()
        let repository = TrackRepository(database)
        for index in 0 ..< presentCount {
            let track = try repository.insert(makeRecord(index: index, availability: .present))
            guard index < analyzedCount, let trackId = track.id else { continue }
            try analyse(database, trackIds: [trackId])
        }
        for index in 0 ..< missingCount {
            _ = try repository.insert(makeRecord(index: presentCount + index, availability: .missing))
        }
        return database
    }

    /// Writes a current, fingerprint-matching analysis row for each id.
    static func analyse(_ database: AppDatabase, trackIds: [Int64]) throws {
        try database.writer.write { db in
            for trackId in trackIds {
                try TrackAudioFeatureRecord(
                    trackId: trackId,
                    fileSize: fileSize,
                    mtime: mtime,
                    bpm: 120,
                    energy: 0.5,
                    brightness: 0.5,
                    analysisVersion: AudioAnalysisService.analysisVersion,
                    computedAt: 0
                ).upsert(db)
            }
        }
    }

    /// Rewrites one row's fingerprint so it no longer describes the file on disk.
    static func staleFingerprint(_ database: AppDatabase, trackId: Int64) throws {
        try database.writer.write { db in
            try db.execute(
                sql: "UPDATE trackAudioFeature SET mtime = ? WHERE trackId = ?",
                arguments: [mtime + 1, trackId]
            )
        }
    }

    private static func makeRecord(index: Int, availability: Availability) -> TrackRecord {
        TrackRecord(
            filePath: "/music/track-\(index).flac",
            title: "Track \(index)",
            sortTitle: "track \(index)",
            fileSize: fileSize,
            mtime: mtime,
            availability: availability
        )
    }
}
