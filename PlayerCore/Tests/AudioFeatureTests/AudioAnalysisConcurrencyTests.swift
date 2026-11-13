// AudioAnalysisConcurrencyTests — the bounded fan-out of one page.
//
// Every case here sizes its fixture from `AudioAnalysisService.concurrencyCap`
// rather than a literal, because the cap is derived from the host's core count:
// a hard-coded 8 would assert nothing on a 4-core machine and overflow the page
// on a 24-core one.
//
// The overlap cases use `ConcurrencyRecordingExtractor(held:)`, so the assertions
// describe the pass's steady state instead of racing a timer.
import Foundation
import Persistence
import PlayerCoreTestSupport
import Services
import Testing

@MainActor
@Suite("AudioAnalysisConcurrencyTests")
struct AudioAnalysisConcurrencyTests {
    /// More tracks than the cap, so a page both saturates the pre-spawn and has
    /// work left over for the add-one-per-completion half of the loop.
    static let trackCount = AudioAnalysisService.concurrencyCap + 4

    @Test("a page runs several extractions at once, and never more than the cap")
    func fansOutUpToTheCap() async throws {
        let database = try AppDatabase.makeEmpty()
        try insertTracks(database, count: Self.trackCount)
        let extractor = ConcurrencyRecordingExtractor(held: true)
        let service = makeService(database, extractor)

        service.start()
        await pollUntil { extractor.inFlightCount >= AudioAnalysisService.concurrencyCap }

        #expect(extractor.maxObservedConcurrency > 1, "the pass is still serial")
        #expect(extractor.maxObservedConcurrency <= AudioAnalysisService.concurrencyCap)
        #expect(extractor.startCount == AudioAnalysisService.concurrencyCap, "the pre-spawn overran the cap")

        extractor.release()
        await pollUntil { !service.isRunning }

        #expect(extractor.maxObservedConcurrency <= AudioAnalysisService.concurrencyCap)
        #expect(service.progress.completed == Self.trackCount)
        #expect(service.progress.total == Self.trackCount)
        #expect(service.failedCount == 0)
        #expect(extractor.startCount == Self.trackCount)
        #expect(try featureCount(database) == Self.trackCount)
    }

    @Test("pause starts no further extraction, and resume finishes the page")
    func pauseStopsNewStartsOnly() async throws {
        let database = try AppDatabase.makeEmpty()
        try insertTracks(database, count: Self.trackCount)
        let extractor = ConcurrencyRecordingExtractor(held: true)
        let service = makeService(database, extractor)

        service.start()
        await pollUntil { extractor.inFlightCount >= AudioAnalysisService.concurrencyCap }
        service.pause()
        // Letting the held extractions return proves the gate is on the SPAWN and
        // not on the completion: work in flight finishes, nothing new begins.
        extractor.release()
        await pollUntil { extractor.inFlightCount == 0 }
        try await Task.sleep(for: .milliseconds(300))

        #expect(service.isRunning)
        #expect(extractor.startCount == AudioAnalysisService.concurrencyCap, "a paused pass started a new extraction")

        service.resume()
        await pollUntil { !service.isRunning }

        #expect(service.progress.completed == Self.trackCount)
        #expect(extractor.startCount == Self.trackCount)
        #expect(Set(extractor.requestedURLs).count == Self.trackCount, "resume re-analysed a track already done")
        #expect(try featureCount(database) == Self.trackCount)
    }

    @Test("stopping mid-page drains cleanly and counts nothing twice")
    func stopMidPageDrainsWithoutOvercounting() async throws {
        let database = try AppDatabase.makeEmpty()
        try insertTracks(database, count: Self.trackCount)
        let extractor = ConcurrencyRecordingExtractor(held: true)
        let service = makeService(database, extractor)

        service.start()
        await pollUntil { extractor.inFlightCount >= AudioAnalysisService.concurrencyCap }
        service.stop()
        await pollUntil { extractor.inFlightCount == 0 }
        try await Task.sleep(for: .milliseconds(200))

        #expect(service.isRunning == false)
        #expect(service.failedCount == 0, "a cancelled extraction was tallied as a failure")
        #expect(service.progress.completed + service.failedCount <= Self.trackCount)
        #expect(extractor.startCount <= Self.trackCount)
        #expect(try featureCount(database) <= Self.trackCount)
    }

    @Test("one throwing file is tallied while the rest of the page still lands")
    func oneFailureDoesNotStallTheFanOut() async throws {
        let database = try AppDatabase.makeEmpty()
        let tracks = try insertTracks(database, count: Self.trackCount)
        let corrupt = url(of: tracks[1])
        let extractor = ConcurrencyRecordingExtractor(failing: [corrupt])
        let service = makeService(database, extractor)

        service.start()
        await pollUntil { !service.isRunning }

        #expect(service.progress.completed == Self.trackCount)
        #expect(service.failedCount == 1)
        #expect(extractor.startCount == Self.trackCount)
        #expect(try featureCount(database) == Self.trackCount - 1)
        let corruptId = try #require(tracks[1].id)
        #expect(try fetchFeature(database, trackId: corruptId) == nil)
    }

    /// Coalescing throttles the per-completion notifications, so the guarantee
    /// that matters is that the LAST one an observer receives is the finished
    /// pass — never a stale mid-page tick the page-exit flush forgot to replace.
    @Test("the last onChange an observer receives describes the finished pass")
    func coalescingNeverSwallowsTheTerminalState() async throws {
        let database = try AppDatabase.makeEmpty()
        try insertTracks(database, count: Self.trackCount)
        let extractor = ConcurrencyRecordingExtractor()
        let service = makeService(database, extractor)
        let observer = TerminalStateObserver()
        service.onChange = { [weak service] in
            guard let service else { return }
            observer.record(isRunning: service.isRunning, completed: service.progress.completed)
        }

        service.start()
        await pollUntil { !service.isRunning }
        await pollUntil { observer.last?.isRunning == false }

        let last = try #require(observer.last)
        #expect(last.isRunning == false)
        #expect(last.completed == Self.trackCount)
        #expect(observer.count < Self.trackCount * 3, "every completion invalidated the observer several times")
    }
}

// MARK: - Construction

private extension AudioAnalysisConcurrencyTests {
    func makeService(
        _ database: AppDatabase,
        _ extractor: any AudioFeatureExtracting
    ) -> AudioAnalysisService {
        AudioAnalysisService(
            database: database,
            extractor: extractor,
            now: { FeatureFixtures.epoch },
            pageSize: trackCount * 2
        )
    }

    var trackCount: Int {
        Self.trackCount
    }
}

/// Remembers the most recent `onChange` payload, so a test can assert on the
/// notification an observer actually ends up holding.
@MainActor
final class TerminalStateObserver {
    private(set) var last: (isRunning: Bool, completed: Int)?
    private(set) var count = 0

    func record(isRunning: Bool, completed: Int) {
        last = (isRunning, completed)
        count += 1
    }
}
