// CueLoudnessPoolingTests — per-segment loudness, and the two grouping rules that
// partition the track set.
//
// A CUE disc image breaks two assumptions the loudness cache was built on. The
// first is that `track.filePath` identifies a measurement: N segments share one
// file, so the staleness fingerprint has to carry each row's OWN cue bounds or
// every segment is either permanently stale or answered by its neighbour's row.
// The second is that `albumId` is the only album a track can belong to: a cue row
// carries one AND belongs to its sheet, so the two pooling rules must be selected
// by complementary predicates or a segment is pooled twice and the surviving
// figure is whichever write landed last.
//
// The oracle every pooled figure is measured against is todo 4's own definition,
// `LoudnessGating.integratedLoudness(ofAbsoluteGatedBlocks:)` over the
// CONCATENATED block sets of the group, exactly as in `AlbumGainPoolingTests`.
import Foundation
import Persistence
import Services
import Testing

@MainActor
@Suite("CueLoudnessPoolingTests")
struct CueLoudnessPoolingTests {
    private static let imagePath = "/music/image/disc.flac"
    private static let sheetPath = "/music/image/disc.cue"

    private static func oracle(_ members: [LoudnessScanResult]) -> Double? {
        LoudnessGating.integratedLoudness(
            ofAbsoluteGatedBlocks: members.flatMap(\.gatedBlockLoudness)
        )
    }

    /// Non-async on purpose: GRDB's `read` has an `async` twin that an `async`
    /// test body resolves to instead, which then fails to compile.
    private static func libraryCoverage(_ database: AppDatabase) throws -> TrackLoudnessCoverage {
        try database.writer.read { db in
            try TrackLoudnessCoverageReader.libraryCoverage(
                db,
                analysisVersion: LoudnessScanService.analysisVersion
            )
        }
    }

    // MARK: - (c) the fingerprint is per segment, not per file

    @Test("two segments of one file produce two distinct rows with distinct gains")
    func twoSegmentsOfOneFileStoreDistinctLoudness() async throws {
        let database = try AppDatabase.makeEmpty()
        let first = try insertCueScanTrack(
            database, path: Self.imagePath, sheetPath: Self.sheetPath, startFrame: 0, endFrame: 2250
        )
        let second = try insertCueScanTrack(
            database, path: Self.imagePath, sheetPath: Self.sheetPath, startFrame: 2250
        )
        let firstId = try #require(first.id)
        let secondId = try #require(second.id)

        let quiet = ScanResultFixtures.make(loudness: -23.02, blocks: 77, truePeak: 0.071)
        let loud = ScanResultFixtures.make(loudness: -13.37, blocks: 37, truePeak: 0.219)
        let scanner = SequencedLoudnessScanner()
        scanner.enqueue(quiet, forPath: Self.imagePath)
        scanner.enqueue(loud, forPath: Self.imagePath)
        let service = makeScanService(database, scanner, pageSize: 1)

        service.start()
        await pollUntil { !service.isRunning }

        try #expect(loudnessRowCount(database) == 2, "one row per SEGMENT, not one per file")
        let firstRow = try requireLoudness(database, trackId: firstId)
        let secondRow = try requireLoudness(database, trackId: secondId)
        let quietLUFS = try #require(firstRow.integratedLUFS)
        let loudLUFS = try #require(secondRow.integratedLUFS)
        #expect(abs(quietLUFS + 23.02) < 0.001)
        #expect(abs(loudLUFS + 13.37) < 0.001)
        let quietGain = try #require(ReplayGainSynthesis.gainDB(forIntegratedLUFS: quietLUFS))
        let loudGain = try #require(ReplayGainSynthesis.gainDB(forIntegratedLUFS: loudLUFS))
        #expect(abs(quietGain - loudGain) > 9, "a shared row would give the two segments one gain")

        // The fingerprint carries each row's OWN bounds — the half of it that was
        // pinned to the whole-file sentinel until `track` grew the columns.
        #expect(firstRow.cueStartFrame == 0)
        #expect(firstRow.cueEndFrame == 2250)
        #expect(secondRow.cueStartFrame == 2250)
        #expect(secondRow.cueEndFrame == nil)
        #expect(!firstRow.fingerprint.isWholeFile)
    }

    @Test("a scanned cue segment stops being a stale candidate")
    func aScannedSegmentIsNoLongerStale() async throws {
        let database = try AppDatabase.makeEmpty()
        try insertCueScanTrack(
            database, path: Self.imagePath, sheetPath: Self.sheetPath, startFrame: 0, endFrame: 2250
        )
        try insertCueScanTrack(
            database, path: Self.imagePath, sheetPath: Self.sheetPath, startFrame: 2250
        )
        let scanner = SequencedLoudnessScanner()
        scanner.enqueue(ScanResultFixtures.quiet, forPath: Self.imagePath)
        scanner.enqueue(ScanResultFixtures.quiet, forPath: Self.imagePath)
        let first = makeScanService(database, scanner, pageSize: 1)
        first.start()
        await pollUntil { !first.isRunning }
        #expect(first.progress.total == 2)

        // A staleness clause pinned to the whole-file sentinel matches no segment
        // row, so this second pass would find both stale again — forever.
        let second = makeScanService(database, SequencedLoudnessScanner(), pageSize: 1)
        second.start()
        await pollUntil { !second.isRunning }

        #expect(second.progress.total == 0, "the cue-aware fingerprint terminates")
        #expect(second.failedCount == 0)
        let coverage = try Self.libraryCoverage(database)
        #expect(coverage.analyzed == 2, "the coverage twin agrees with the pass")
        #expect(coverage.stale == 0)
    }

    // MARK: - (d)(i) the disagreement fixture

    @Test("cue segments sharing an albumId with a non-cue track pool separately")
    func cueSegmentsAndAnAlbumMateDoNotPoolTogether() async throws {
        let database = try AppDatabase.makeEmpty()
        let albumId = try insertAlbum(database, title: "Disputed")
        let first = try insertCueScanTrack(
            database, path: Self.imagePath, sheetPath: Self.sheetPath,
            startFrame: 0, endFrame: 2250, albumId: albumId
        )
        let second = try insertCueScanTrack(
            database, path: Self.imagePath, sheetPath: Self.sheetPath,
            startFrame: 2250, albumId: albumId
        )
        let bonus = try insertScanTrack(database, path: "/music/image/bonus.flac", albumId: albumId)
        let firstId = try #require(first.id)
        let secondId = try #require(second.id)
        let bonusId = try #require(bonus.id)

        let quiet = ScanResultFixtures.make(loudness: -23.02, blocks: 77, truePeak: 0.071)
        let loud = ScanResultFixtures.make(loudness: -13.37, blocks: 37, truePeak: 0.219)
        let outsider = ScanResultFixtures.make(loudness: -20.0, blocks: 50, truePeak: 0.5)
        let scanner = SequencedLoudnessScanner()
        scanner.enqueue(quiet, forPath: Self.imagePath)
        scanner.enqueue(loud, forPath: Self.imagePath)
        scanner.enqueue(outsider, forPath: bonus.filePath)
        let service = makeScanService(database, scanner, pageSize: 1)

        service.start()
        await pollUntil { !service.isRunning }

        let sheetPool = try #require(Self.oracle([quiet, loud]))
        let wouldBeMerged = try #require(Self.oracle([quiet, loud, outsider]))
        let firstRow = try requireLoudness(database, trackId: firstId)
        let secondRow = try requireLoudness(database, trackId: secondId)
        let bonusRow = try requireLoudness(database, trackId: bonusId)

        let segmentFigure = try #require(firstRow.albumLUFS)
        #expect(abs(segmentFigure - sheetPool) < 0.1, "segments pool by cueSheetPath ONLY")
        #expect(abs(segmentFigure - wouldBeMerged) > 0.1, "the album-mate is not in the sheet's pool")
        #expect(secondRow.albumLUFS == segmentFigure)
        #expect(firstRow.albumPeak == 0.219, "albumPeak is the max across the SHEET, not the albumId")
        #expect(secondRow.albumPeak == 0.219)

        // The non-cue track is the only whole-file member of its albumId, so its
        // album figure is its own. Double-pooling would have given it the sheet's.
        let bonusFigure = try #require(bonusRow.albumLUFS)
        #expect(abs(bonusFigure + 20.0) < 0.1)
        #expect(abs(bonusFigure - segmentFigure) > 1, "the two rules genuinely disagree here")
        #expect(bonusRow.albumPeak == 0.5)
    }

    // MARK: - (d)(ii) the multi-FILE sheet

    @Test("every segment of a multi-FILE cue sheet shares one album figure")
    func multiFileSheetSegmentsShareOneAlbumFigure() async throws {
        let database = try AppDatabase.makeEmpty()
        let sheet = "/music/multi/album.cue"
        let paths = (1 ... 3).map { "/music/multi/0\($0).flac" }
        // A multi-FILE sheet gives each segment its OWN file and a start frame of
        // 0, and these rows carry NO albumId — so filePath grouping would leave
        // three singleton groups whose album figure degenerates to the track's.
        let tracks = try paths.map {
            try insertCueScanTrack(database, path: $0, sheetPath: sheet, startFrame: 0)
        }
        let results = [
            ScanResultFixtures.make(loudness: -21.13, blocks: 60, truePeak: 0.31),
            ScanResultFixtures.make(loudness: -17.44, blocks: 45, truePeak: 0.62),
            ScanResultFixtures.make(loudness: -25.71, blocks: 90, truePeak: 0.18),
        ]
        let scanner = SequencedLoudnessScanner()
        for (path, result) in zip(paths, results) {
            scanner.enqueue(result, forPath: path)
        }
        let service = makeScanService(database, scanner, pageSize: 1)

        service.start()
        await pollUntil { !service.isRunning }

        let expected = try #require(Self.oracle(results))
        var figures: [Double] = []
        var ownFigures: [Double] = []
        for track in tracks {
            let trackId = try #require(track.id)
            let row = try requireLoudness(database, trackId: trackId)
            let figure = try #require(row.albumLUFS)
            let own = try #require(row.integratedLUFS)
            figures.append(figure)
            ownFigures.append(own)
            #expect(row.albumPeak == 0.62, "one peak, the loudest sample on the sheet")
        }
        let highest = try #require(figures.max())
        let lowest = try #require(figures.min())
        #expect(highest == lowest, "one sheet, one album figure")
        #expect(abs(highest - expected) < 0.1, "pooled \(highest) vs oracle \(expected)")
        // The three track figures are pairwise distinct, so grouping by filePath
        // — three singleton groups, each pooling to its own member — could not
        // have produced one shared figure.
        #expect(Set(ownFigures.map { ($0 * 100).rounded() }).count == 3)
    }

    // MARK: - the grouping key's fallback

    @Test("segments written without a sheet path fall back to grouping by file path")
    func sheetlessSegmentsGroupByFilePath() async throws {
        let database = try AppDatabase.makeEmpty()
        let first = try insertCueScanTrack(
            database, path: Self.imagePath, sheetPath: nil, startFrame: 0, endFrame: 2250
        )
        let second = try insertCueScanTrack(
            database, path: Self.imagePath, sheetPath: nil, startFrame: 2250
        )
        let firstId = try #require(first.id)
        let secondId = try #require(second.id)

        let quiet = ScanResultFixtures.make(loudness: -23.02, blocks: 77, truePeak: 0.071)
        let loud = ScanResultFixtures.make(loudness: -13.37, blocks: 37, truePeak: 0.219)
        let scanner = SequencedLoudnessScanner()
        scanner.enqueue(quiet, forPath: Self.imagePath)
        scanner.enqueue(loud, forPath: Self.imagePath)
        let service = makeScanService(database, scanner, pageSize: 1)

        service.start()
        await pollUntil { !service.isRunning }

        let expected = try #require(Self.oracle([quiet, loud]))
        let firstRow = try requireLoudness(database, trackId: firstId)
        let secondRow = try requireLoudness(database, trackId: secondId)
        let pooled = try #require(firstRow.albumLUFS)
        #expect(abs(pooled - expected) < 0.1)
        #expect(secondRow.albumLUFS == pooled)
    }
}
