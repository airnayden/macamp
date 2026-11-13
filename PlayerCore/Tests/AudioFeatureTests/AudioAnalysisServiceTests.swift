// AudioAnalysisServiceTests — the staleness contract of the library-wide pass,
// driven through an in-memory database and the file-free feature extractor.
//
// Every case here asks the same question: which tracks does the pass CHOOSE?
// Transport (pause / resume / stop / failure counting) lives in the +Transport
// file.
import Foundation
import Persistence
import PlayerCoreTestSupport
import Services
import Testing

@MainActor
@Suite("AudioAnalysisServiceTests")
struct AudioAnalysisServiceTests {
    @Test("a full pass analyses every stale track and reports (10, 10)")
    func analysesWholeLibrary() async throws {
        let database = try AppDatabase.makeEmpty()
        let tracks = try insertTracks(database, count: 10)
        let extractor = FakeAudioFeatureExtractor(returning: FeatureFixtures.result)
        let service = makeService(database, extractor)

        service.start()
        await pollUntil { !service.isRunning }

        #expect(service.progress.completed == 10)
        #expect(service.progress.total == 10)
        #expect(service.failedCount == 0)
        #expect(extractor.extractCallCount == 10)
        let rows = try featureCount(database)
        #expect(rows == 10)

        let first = try #require(tracks.first?.id)
        let stored = try fetchFeature(database, trackId: first)
        let row = try #require(stored)
        #expect(row.bpm == FeatureFixtures.result.bpm)
        #expect(row.energy == FeatureFixtures.result.energy)
        #expect(row.brightness == FeatureFixtures.result.brightness)
        #expect(row.fileSize == Fingerprint.fileSize)
        #expect(row.mtime == Fingerprint.mtime)
        #expect(row.analysisVersion == AudioAnalysisService.analysisVersion)
        #expect(row.computedAt == FeatureFixtures.epoch.timeIntervalSince1970)
    }

    @Test("a track whose fingerprint still matches is skipped, not re-analysed")
    func skipsFreshFingerprints() async throws {
        let database = try AppDatabase.makeEmpty()
        let tracks = try insertTracks(database, count: 3)
        let fresh = try #require(tracks.first?.id)
        try insertFeature(database, trackId: fresh)
        let extractor = FakeAudioFeatureExtractor(returning: FeatureFixtures.result)
        let service = makeService(database, extractor)

        service.start()
        await pollUntil { !service.isRunning }

        #expect(service.progress.total == 2)
        #expect(service.progress.completed == 2)
        #expect(extractor.extractCallCount == 2)
        #expect(!extractor.requestedURLs.contains(url(of: tracks[0])))

        let stored = try fetchFeature(database, trackId: fresh)
        let row = try #require(stored)
        #expect(row.bpm == 90, "the fresh row was rewritten")
    }

    @Test("a track whose (fileSize, mtime) changed is re-analysed in place")
    func redoesStaleFingerprints() async throws {
        let database = try AppDatabase.makeEmpty()
        let tracks = try insertTracks(database, count: 1)
        let trackId = try #require(tracks.first?.id)
        try insertFeature(database, trackId: trackId, fileSize: 512, mtime: 50)
        let extractor = FakeAudioFeatureExtractor(returning: FeatureFixtures.result)
        let service = makeService(database, extractor)

        service.start()
        await pollUntil { !service.isRunning }

        #expect(service.progress.total == 1)
        #expect(extractor.extractCallCount == 1)
        let rows = try featureCount(database)
        #expect(rows == 1, "the upsert inserted a duplicate instead of overwriting")

        let stored = try fetchFeature(database, trackId: trackId)
        let row = try #require(stored)
        #expect(row.bpm == FeatureFixtures.result.bpm)
        #expect(row.fileSize == Fingerprint.fileSize)
        #expect(row.mtime == Fingerprint.mtime)
    }

    @Test("a row written by an older extractor version is recomputed")
    func redoesOlderAnalysisVersions() async throws {
        let database = try AppDatabase.makeEmpty()
        let tracks = try insertTracks(database, count: 1)
        let trackId = try #require(tracks.first?.id)
        try insertFeature(database, trackId: trackId, analysisVersion: AudioAnalysisService.analysisVersion - 1)
        let extractor = FakeAudioFeatureExtractor(returning: FeatureFixtures.result)
        let service = makeService(database, extractor)

        service.start()
        await pollUntil { !service.isRunning }

        #expect(service.progress.total == 1)
        let stored = try fetchFeature(database, trackId: trackId)
        let row = try #require(stored)
        #expect(row.analysisVersion == AudioAnalysisService.analysisVersion)
        #expect(row.bpm == FeatureFixtures.result.bpm)
    }

    @Test("missing and external-offline tracks are never analysed")
    func skipsUnavailableTracks() async throws {
        let database = try AppDatabase.makeEmpty()
        let present = try insertTrack(database, path: "/music/present.flac")
        try insertTrack(database, path: "/gone/missing.flac", availability: .missing)
        try insertTrack(database, path: "/volume/offline.flac", availability: .externalOffline)
        let extractor = FakeAudioFeatureExtractor(returning: FeatureFixtures.result)
        let service = makeService(database, extractor)

        service.start()
        await pollUntil { !service.isRunning }

        #expect(service.progress.total == 1)
        #expect(extractor.requestedURLs == [url(of: present)])
        let rows = try featureCount(database)
        #expect(rows == 1)
    }

    @Test("a track with no recorded fingerprint is analysed once, then treated as fresh")
    func nilFingerprintTerminates() async throws {
        let database = try AppDatabase.makeEmpty()
        let track = try insertTrack(database, path: "/music/nofp.flac", fileSize: nil, mtime: nil)
        let trackId = try #require(track.id)
        let extractor = FakeAudioFeatureExtractor(returning: FeatureFixtures.result)
        let service = makeService(database, extractor)

        service.start()
        await pollUntil { !service.isRunning }

        #expect(extractor.extractCallCount == 1)
        let stored = try fetchFeature(database, trackId: trackId)
        let row = try #require(stored)
        #expect(row.fileSize == 0)
        #expect(row.mtime == 0)

        service.start()
        await pollUntil { !service.isRunning }

        #expect(service.progress.total == 0, "a nil-fingerprint track looked stale forever")
        #expect(extractor.extractCallCount == 1)
    }

    @Test("a second pass over an analysed library does nothing")
    func secondPassIsANoOp() async throws {
        let database = try AppDatabase.makeEmpty()
        try insertTracks(database, count: 4)
        let extractor = FakeAudioFeatureExtractor(returning: FeatureFixtures.result)
        let service = makeService(database, extractor)

        service.start()
        await pollUntil { !service.isRunning }
        #expect(extractor.extractCallCount == 4)

        service.start()
        await pollUntil { !service.isRunning }

        #expect(service.progress.total == 0)
        #expect(service.progress.completed == 0)
        #expect(extractor.extractCallCount == 4)
    }

    @Test("the outcome does not depend on page size", arguments: [1, 3, 500])
    func pageSizeIndependence(pageSize: Int) async throws {
        let database = try AppDatabase.makeEmpty()
        try insertTracks(database, count: 7)
        let extractor = FakeAudioFeatureExtractor(returning: FeatureFixtures.result)
        let service = makeService(database, extractor, pageSize: pageSize)

        service.start()
        await pollUntil { !service.isRunning }

        #expect(service.progress.completed == 7)
        #expect(service.progress.total == 7)
        #expect(extractor.extractCallCount == 7)
        let rows = try featureCount(database)
        #expect(rows == 7)
    }
}

// MARK: - Construction

extension AudioAnalysisServiceTests {
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
