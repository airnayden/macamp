// LoudnessScanServiceTests — the batch pass: which tracks does it CHOOSE, what
// does it commit, and does an interruption cost anything?
//
// The database IS the progress record, so every case here is ultimately about
// that one claim: a row's presence is what makes its track stop being a
// candidate, and its absence is what keeps a failed track's album group open.
import Foundation
import Persistence
import Services
import Testing

@MainActor
@Suite("LoudnessScanServiceTests")
struct LoudnessScanServiceTests {
    @Test("a full pass scans every stale track and commits a fingerprinted row")
    func scansWholeLibrary() async throws {
        let database = try AppDatabase.makeEmpty()
        let tracks = try (1 ... 5).map { try insertScanTrack(database, path: "/music/t\($0).flac") }
        let scanner = StubLoudnessScanner()
        for track in tracks {
            scanner.stub(ScanResultFixtures.quiet, forPath: track.filePath)
        }
        let service = makeScanService(database, scanner)

        service.start()
        await pollUntil { !service.isRunning }

        #expect(service.progress.completed == 5)
        #expect(service.progress.total == 5)
        #expect(service.failedCount == 0)
        let rowCount = try loudnessRowCount(database)
        #expect(rowCount == 5)

        let trackId = try #require(tracks.first?.id)
        let row = try requireLoudness(database, trackId: trackId)
        let lufs = try #require(row.integratedLUFS)
        #expect(abs(lufs + 23.0) < 0.001)
        #expect(row.truePeak == ScanResultFixtures.quiet.truePeak)
        #expect(row.albumLUFS == nil, "no albumId means no album gain")
        #expect(row.albumPeak == nil)
        #expect(row.blockPowersHistogram != nil)
        #expect(row.analysisVersion == LoudnessScanService.analysisVersion)
        #expect(row.fileSize == ScanFixtures.fileSize)
        #expect(row.mtime == ScanFixtures.mtime)
        #expect(row.cueStartFrame == TrackLoudnessFingerprint.wholeFileCueStartFrame)
        #expect(row.cueEndFrame == nil)
        #expect(row.computedAt == ScanFixtures.epoch.timeIntervalSince1970)
    }

    @Test("a re-scan with an unchanged fingerprint performs zero decodes")
    func rescanPerformsZeroDecodes() async throws {
        let database = try AppDatabase.makeEmpty()
        let provider = PlanarBufferDecoderProvider()
        for index in 1 ... 3 {
            let path = "/music/t\(index).flac"
            try insertScanTrack(database, path: path)
            provider.register(ScanFixtures.stereoTone(dBFS: -20, seconds: 1), forPath: path)
        }
        let scanner = LoudnessScanner(decoderProvider: provider)

        let first = makeScanService(database, scanner)
        first.start()
        await pollUntil { !first.isRunning }
        #expect(provider.decodeCallCount > 0)
        let seeded = try loudnessRowCount(database)
        #expect(seeded == 3)

        provider.resetCounts()
        let second = makeScanService(database, scanner)
        second.start()
        await pollUntil { !second.isRunning }

        #expect(second.progress.total == 0)
        #expect(provider.openCount == 0, "a fresh fingerprint must not reopen the file")
        #expect(provider.decodeCallCount == 0)
    }

    @Test("an interrupted batch resumes from database state, keeping what it committed")
    func interruptedBatchResumes() async throws {
        let database = try AppDatabase.makeEmpty()
        let tracks = try (1 ... 4).map { try insertScanTrack(database, path: "/music/t\($0).flac") }
        let blocking = BlockingLoudnessScanner(blockAfter: 2)
        let first = makeScanService(database, blocking, pageSize: 1)

        first.start()
        await pollUntil { (try? loudnessRowCount(database)) == 2 }
        first.stop()

        let committed = try loudnessRowCount(database)
        #expect(committed == 2)
        #expect(!first.isRunning)

        let resuming = StubLoudnessScanner()
        for track in tracks {
            resuming.stub(ScanResultFixtures.quiet, forPath: track.filePath)
        }
        let second = makeScanService(database, resuming, pageSize: 1)
        second.start()
        await pollUntil { !second.isRunning }

        #expect(second.progress.total == 2, "only the two never-committed tracks are still stale")
        #expect(resuming.scanCallCount == 2)
        let total = try loudnessRowCount(database)
        #expect(total == 4)
    }

    @Test("a failed track writes no row, is tallied, and the batch continues")
    func failureWritesNoRow() async throws {
        let database = try AppDatabase.makeEmpty()
        let tracks = try (1 ... 3).map { try insertScanTrack(database, path: "/music/t\($0).flac") }
        let scanner = StubLoudnessScanner()
        scanner.stub(ScanResultFixtures.quiet, forPath: tracks[0].filePath)
        scanner.stub(ScanResultFixtures.quiet, forPath: tracks[2].filePath)
        let service = makeScanService(database, scanner)

        service.start()
        await pollUntil { !service.isRunning }

        #expect(service.progress.completed == 3)
        #expect(service.progress.total == 3)
        #expect(service.failedCount == 1)
        let rowCount = try loudnessRowCount(database)
        #expect(rowCount == 2)
        let failedId = try #require(tracks[1].id)
        let failedRow = try fetchLoudness(database, trackId: failedId)
        #expect(failedRow == nil)
    }

    @Test("a missing track is never a candidate")
    func skipsMissingTracks() async throws {
        let database = try AppDatabase.makeEmpty()
        try insertScanTrack(database, path: "/music/present.flac")
        try insertScanTrack(database, path: "/music/gone.flac", availability: .missing)
        let scanner = StubLoudnessScanner()
        scanner.stub(ScanResultFixtures.quiet, forPath: "/music/present.flac")
        let service = makeScanService(database, scanner)

        service.start()
        await pollUntil { !service.isRunning }

        #expect(service.progress.total == 1)
        let rowCount = try loudnessRowCount(database)
        #expect(rowCount == 1)
    }

    @Test("startFullReanalysis discards every row and re-scans the library")
    func fullReanalysisDiscardsRows() async throws {
        let database = try AppDatabase.makeEmpty()
        let tracks = try (1 ... 3).map { try insertScanTrack(database, path: "/music/t\($0).flac") }
        let scanner = StubLoudnessScanner()
        for track in tracks {
            scanner.stub(ScanResultFixtures.quiet, forPath: track.filePath)
        }
        let service = makeScanService(database, scanner)

        service.start()
        await pollUntil { !service.isRunning }
        #expect(scanner.scanCallCount == 3)

        service.startFullReanalysis()
        await pollUntil { !service.isRunning && scanner.scanCallCount == 6 }

        #expect(service.progress.total == 3)
        let rowCount = try loudnessRowCount(database)
        #expect(rowCount == 3)
    }

    @Test("pause holds the pass and resume releases it")
    func pauseAndResume() async throws {
        let database = try AppDatabase.makeEmpty()
        let tracks = try (1 ... 4).map { try insertScanTrack(database, path: "/music/t\($0).flac") }
        let scanner = StubLoudnessScanner()
        for track in tracks {
            scanner.stub(ScanResultFixtures.quiet, forPath: track.filePath)
        }
        let service = makeScanService(database, scanner, pageSize: 1)

        service.start()
        service.pause()
        #expect(service.isPaused)
        #expect(service.isRunning)

        service.resume()
        await pollUntil { !service.isRunning }

        #expect(!service.isPaused)
        let rowCount = try loudnessRowCount(database)
        #expect(rowCount == 4)
    }
}
