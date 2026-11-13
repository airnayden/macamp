// AudioAnalysisRescanTests — the forced full pass, and why it needed to exist.
//
// `start()` is fingerprint-driven, so on a fully analysed library it correctly
// does nothing: `staleTrackCount` is 0 and the first page is empty. That is right
// for the incremental button and useless as a recovery path, because a
// measurement can be wrong for reasons the `(fileSize, mtime)` fingerprint cannot
// see. `startFullReanalysis()` discards the cache first, which is the whole of the
// "force" mode — no second staleness definition, so nothing can drift out of step
// with `AudioFeatureCoverageReader`'s positive twin.
//
// A separate file from `AudioAnalysisServiceTests` only because that suite's body
// is already close to SwiftLint's `type_body_length` ceiling.
import Foundation
import Persistence
import PlayerCoreTestSupport
import Services
import Testing

@MainActor
@Suite("AudioAnalysisRescanTests")
struct AudioAnalysisRescanTests {
    /// The control: on a fully analysed library the INCREMENTAL pass is a no-op,
    /// which is exactly the state the listener is stuck in.
    @Test("start is a no-op on a fully analysed library")
    func startIsANoOpOnAFullyAnalysedLibrary() async throws {
        let database = try AppDatabase.makeEmpty()
        let tracks = try insertTracks(database, count: 3)
        for track in tracks {
            try insertFeature(database, trackId: #require(track.id))
        }
        let extractor = FakeAudioFeatureExtractor(returning: FeatureFixtures.result)
        let service = makeService(database, extractor)

        service.start()
        await pollUntil { !service.isRunning }

        #expect(extractor.extractCallCount == 0)
        #expect(try featureCount(database) == 3)
    }

    /// The fix, on the same library: every row is discarded and recomputed even
    /// though not one fingerprint changed.
    @Test("a forced pass re-analyses every track on a fully analysed library")
    func aForcedPassReAnalysesEveryTrack() async throws {
        let database = try AppDatabase.makeEmpty()
        let tracks = try insertTracks(database, count: 3)
        for track in tracks {
            try insertFeature(database, trackId: #require(track.id))
        }
        let extractor = FakeAudioFeatureExtractor(returning: FeatureFixtures.result)
        let service = makeService(database, extractor)

        service.startFullReanalysis()
        await pollUntil { !service.isRunning }

        #expect(extractor.extractCallCount == 3)
        #expect(service.progress == (3, 3))
        #expect(try featureCount(database) == 3, "the rows are replaced, never duplicated")
        let stored = try fetchFeature(database, trackId: #require(tracks.first?.id))
        let row = try #require(stored)
        #expect(row.energy == FeatureFixtures.result.energy, "and carry the fresh measurement")
        // `insertFeature` seeds `computedAt: 0`; the pass stamps the injected clock.
        // The fingerprint never changed, so this is the ONLY evidence the row was
        // rewritten rather than left alone.
        #expect(row.computedAt == FeatureFixtures.epoch.timeIntervalSince1970)
    }

    /// Cheap-but-real: the delete must not survive a library that has nothing to
    /// re-analyse, or a listener who confirmed the dialog on an empty library
    /// would be left with fewer rows than they started with for no gain.
    @Test("a forced pass over an empty library leaves an empty table and finishes")
    func aForcedPassOverAnEmptyLibraryFinishes() async throws {
        let database = try AppDatabase.makeEmpty()
        let service = makeService(database, FakeAudioFeatureExtractor(returning: FeatureFixtures.result))

        service.startFullReanalysis()
        await pollUntil { !service.isRunning }

        #expect(try featureCount(database) == 0)
        #expect(service.isRunning == false)
    }

    /// Transport is the ordinary transport: the destructive pass is an ordinary
    /// pass with a `DELETE` in front of it, so stop must leave the rows it already
    /// rewrote committed.
    @Test("a forced pass can be stopped, keeping the rows it already rewrote")
    func aForcedPassCanBeStopped() async throws {
        let database = try AppDatabase.makeEmpty()
        let tracks = try insertTracks(database, count: 4)
        for track in tracks {
            try insertFeature(database, trackId: #require(track.id))
        }
        let extractor = BlockingFeatureExtractor(returning: FeatureFixtures.result, blockAfter: 1)
        let service = makeService(database, extractor)

        service.startFullReanalysis()
        await pollUntil { (try? featureCount(database)) == 1 }
        service.stop()
        await pollUntil { !service.isRunning }

        #expect(try featureCount(database) == 1, "one row rewritten, the rest discarded and not yet redone")
        #expect(service.isRunning == false)
    }

    /// A forced pass requested while one is running must not restart it — a second
    /// `DELETE` would throw away the rows the running pass had just rewritten.
    @Test("a forced pass is a no-op while a pass is already running")
    func aForcedPassIsANoOpWhileRunning() async throws {
        let database = try AppDatabase.makeEmpty()
        try insertTracks(database, count: 4)
        let extractor = BlockingFeatureExtractor(returning: FeatureFixtures.result, blockAfter: 1)
        let service = makeService(database, extractor)

        service.start()
        await pollUntil { (try? featureCount(database)) == 1 }
        service.startFullReanalysis()

        #expect(try featureCount(database) == 1, "the running pass's row survives")
        service.stop()
        await pollUntil { !service.isRunning }
    }
}

// MARK: - Fixture

private extension AudioAnalysisRescanTests {
    func makeService(
        _ database: AppDatabase,
        _ extractor: any AudioFeatureExtracting
    ) -> AudioAnalysisService {
        AudioAnalysisService(
            database: database,
            extractor: extractor,
            now: { FeatureFixtures.epoch },
            pageSize: 50
        )
    }
}
