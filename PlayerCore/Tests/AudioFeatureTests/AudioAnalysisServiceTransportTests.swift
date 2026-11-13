// AudioAnalysisServiceTransportTests — start / pause / resume / stop, plus the
// per-track failure tally that keeps one corrupt file from aborting a library.
//
// The cancellation cases use `BlockingFeatureExtractor` so they assert on state,
// not on a race; only the pause case needs a latency, and its strong assertion
// (every stale track analysed exactly once) is timing-free.
import Foundation
import Persistence
import PlayerCoreTestSupport
import Services
import Testing

@MainActor
@Suite("AudioAnalysisServiceTransportTests")
struct AudioAnalysisServiceTransportTests {
    @Test("constructing the service analyses nothing — the pass is opt-in")
    func constructionNeverAutoStarts() async throws {
        let database = try AppDatabase.makeEmpty()
        try insertTracks(database, count: 5)
        let extractor = FakeAudioFeatureExtractor(returning: FeatureFixtures.result)
        let service = makeService(database, extractor)

        try await Task.sleep(for: .milliseconds(100))

        #expect(service.isRunning == false)
        #expect(service.progress.completed == 0)
        #expect(service.progress.total == 0)
        #expect(extractor.extractCallCount == 0)
        let rows = try featureCount(database)
        #expect(rows == 0)
    }

    @Test("pause holds the pass and resume continues from the cursor")
    func pauseAndResumeContinuesFromCursor() async throws {
        let database = try AppDatabase.makeEmpty()
        try insertTracks(database, count: 10)
        let extractor = FakeAudioFeatureExtractor(
            returning: FeatureFixtures.result,
            latency: .milliseconds(30)
        )
        let service = makeService(database, extractor, pageSize: 3)

        service.start()
        await pollUntil { service.progress.completed >= 2 }
        service.pause()
        #expect(service.isPaused)

        // Ten 30 ms extractions cannot still be outstanding after this wait, so a
        // pass that is STILL running is proof the pause actually held.
        try await Task.sleep(for: .milliseconds(400))
        #expect(service.isRunning)
        #expect(service.progress.completed < 10)

        service.resume()
        #expect(service.isPaused == false)
        await pollUntil { !service.isRunning }

        #expect(service.progress.completed == 10)
        #expect(service.failedCount == 0)
        #expect(extractor.extractCallCount == 10)
        #expect(Set(extractor.requestedURLs).count == 10, "resume re-analysed a track the cursor had passed")
        let rows = try featureCount(database)
        #expect(rows == 10)
    }

    @Test("stop() halts the pass but keeps already-committed rows")
    func stopKeepsCommittedRows() async throws {
        let database = try AppDatabase.makeEmpty()
        try insertTracks(database, count: 5)
        let extractor = BlockingFeatureExtractor(blockAfter: 1)
        let service = makeService(database, extractor)

        service.start()
        await pollUntil { service.progress.completed >= 1 }
        service.stop()
        await pollUntil { !service.isRunning }

        #expect(service.isRunning == false)
        #expect(service.isPaused == false)
        let rows = try featureCount(database)
        #expect(rows == 1)
        // The page starts every track at once, so WHICH one wins the extractor's
        // single non-blocking slot is not determined — the contract is that the one
        // row that landed is complete, not that it belongs to track 1.
        let row = try #require(try allFeatures(database).first)
        #expect(row.bpm == FeatureFixtures.result.bpm)
        #expect(row.analysisVersion == AudioAnalysisService.analysisVersion)
    }

    @Test("a track cancelled in flight is not counted as a failure")
    func cancellationIsNotAFailure() async throws {
        let database = try AppDatabase.makeEmpty()
        try insertTracks(database, count: 5)
        let extractor = BlockingFeatureExtractor(blockAfter: 1)
        let service = makeService(database, extractor)

        service.start()
        await pollUntil { extractor.extractCallCount >= 2 }
        service.stop()
        await pollUntil { !service.isRunning }

        #expect(service.failedCount == 0)
    }

    @Test("an extractor failure records nothing, continues the pass, and is tallied")
    func extractorFailureIsTalliedAndPassContinues() async throws {
        let database = try AppDatabase.makeEmpty()
        let tracks = try insertTracks(database, count: 10)
        let corrupt = url(of: tracks[2])
        let corruptId = try #require(tracks[2].id)
        let extractor = FakeAudioFeatureExtractor(returning: FeatureFixtures.result)
        extractor.setError(.decodeFailed(url: corrupt, reason: "corrupt fixture"), for: corrupt)
        let service = makeService(database, extractor)

        service.start()
        await pollUntil { !service.isRunning }

        #expect(service.progress.completed == 10)
        #expect(service.progress.total == 10)
        #expect(service.failedCount == 1)
        #expect(extractor.extractCallCount == 10)

        let stored = try fetchFeature(database, trackId: corruptId)
        #expect(stored == nil, "a partial row was written for the failed track")
        let rows = try featureCount(database)
        #expect(rows == 9)
    }

    @Test("a failed track is retried by the next pass")
    func failedTrackStaysStale() async throws {
        let database = try AppDatabase.makeEmpty()
        let tracks = try insertTracks(database, count: 3)
        let corrupt = url(of: tracks[1])
        let extractor = FakeAudioFeatureExtractor(returning: FeatureFixtures.result)
        extractor.setError(.decodeFailed(url: corrupt, reason: "corrupt fixture"), for: corrupt)
        let service = makeService(database, extractor)

        service.start()
        await pollUntil { !service.isRunning }
        #expect(service.failedCount == 1)

        extractor.setError(nil, for: corrupt)
        service.start()
        await pollUntil { !service.isRunning }

        #expect(service.progress.total == 1)
        #expect(service.failedCount == 0)
        let rows = try featureCount(database)
        #expect(rows == 3)
    }

    @Test("start() while running is a no-op")
    func startWhileRunningIsANoOp() async throws {
        let database = try AppDatabase.makeEmpty()
        try insertTracks(database, count: 5)
        let extractor = BlockingFeatureExtractor(blockAfter: 1)
        let service = makeService(database, extractor)

        service.start()
        await pollUntil { service.progress.completed >= 1 }
        service.start()
        #expect(service.progress.completed >= 1, "the second start() reset a running pass")

        service.stop()
        await pollUntil { !service.isRunning }
        #expect(extractor.extractCallCount <= 5)
    }

    @Test("pause/resume/stop drive the running state")
    func controlSurfaceStates() async throws {
        let database = try AppDatabase.makeEmpty()
        try insertTracks(database, count: 3)
        let extractor = BlockingFeatureExtractor(blockAfter: 1)
        let service = makeService(database, extractor)

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
    func stopBeforeStartIsANoOp() throws {
        let database = try AppDatabase.makeEmpty()
        let extractor = FakeAudioFeatureExtractor(returning: FeatureFixtures.result)
        let service = makeService(database, extractor)

        service.stop()

        #expect(service.isRunning == false)
        #expect(extractor.extractCallCount == 0)
    }
}

// MARK: - Construction

extension AudioAnalysisServiceTransportTests {
    func makeService(
        _ database: AppDatabase,
        _ extractor: any AudioFeatureExtracting,
        pageSize: Int = 50
    ) -> AudioAnalysisService {
        AudioAnalysisService(
            database: database,
            extractor: extractor,
            now: { FeatureFixtures.epoch },
            pageSize: pageSize
        )
    }
}
