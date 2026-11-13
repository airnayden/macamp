// AlbumGainPoolingTests — the three rules album gain lives or dies by.
//
// 1. POOLING SOURCE — a member outside the current page contributes its STORED
//    histogram; nothing is ever decoded twice to pool it.
// 2. COMPLETENESS — a group is pooled only when EVERY member has a histogram,
//    and the result then lands on ALL members including previously-finished ones.
// 3. FAIL-CLOSED DENOMINATOR — a member that failed wrote no row and is NOT
//    filtered out of the group; the group stays unpooled. An implementation that
//    filtered failures out would see "1 of 1" and publish a half-album gain, and
//    `undecodableMemberLeavesTheGroupUnpooled` is the test it fails.
//
// The oracle every pooled figure is measured against is todo 4's own definition:
// `LoudnessGating.integratedLoudness(ofAbsoluteGatedBlocks:)` over the
// CONCATENATED block sets of every member. The implementation reaches the same
// answer through the 0.1 dB histogram, so ±0.1 LU is a bin-resolution tolerance,
// not slack.
import Foundation
import Persistence
import Services
import Testing

@MainActor
@Suite("AlbumGainPoolingTests")
struct AlbumGainPoolingTests {
    /// The album figure the raw-block path produces for `members`.
    static func oracle(_ members: [LoudnessScanResult]) -> Double? {
        LoudnessGating.integratedLoudness(
            ofAbsoluteGatedBlocks: members.flatMap(\.gatedBlockLoudness)
        )
    }

    @Test("a two-file album pools to the concatenated-block oracle within 0.1 LU")
    func twoFileAlbumPoolsToOracle() async throws {
        let database = try AppDatabase.makeEmpty()
        let albumId = try insertAlbum(database, title: "Pooled")
        let first = try insertScanTrack(database, path: "/music/a1.flac", albumId: albumId)
        let second = try insertScanTrack(database, path: "/music/a2.flac", albumId: albumId)
        let firstId = try #require(first.id)
        let secondId = try #require(second.id)

        let quiet = ScanResultFixtures.make(loudness: -23.02, blocks: 77, truePeak: 0.071)
        let loud = ScanResultFixtures.make(loudness: -13.37, blocks: 37, truePeak: 0.219)
        let scanner = StubLoudnessScanner()
        scanner.stub(quiet, forPath: first.filePath)
        scanner.stub(loud, forPath: second.filePath)
        let service = makeScanService(database, scanner)

        service.start()
        await pollUntil { !service.isRunning }

        let expected = try #require(Self.oracle([quiet, loud]))
        let firstRow = try requireLoudness(database, trackId: firstId)
        let secondRow = try requireLoudness(database, trackId: secondId)
        let pooled = try #require(firstRow.albumLUFS)
        #expect(abs(pooled - expected) < 0.1, "pooled \(pooled) vs oracle \(expected)")
        #expect(secondRow.albumLUFS == pooled, "both members must carry the same album figure")
        #expect(firstRow.albumPeak == 0.219, "albumPeak is the MAX member true peak")
        #expect(secondRow.albumPeak == 0.219)
        #expect(pooled > -23.02, "pooling is power-weighted, not a per-track LUFS average")
    }

    @Test("a three-track album split across two batches ends with one album figure on all three")
    func splitAlbumEndsWithOneFigure() async throws {
        let database = try AppDatabase.makeEmpty()
        let albumId = try insertAlbum(database, title: "Split")
        let tracks = try (1 ... 3).map {
            try insertScanTrack(database, path: "/music/s\($0).flac", albumId: albumId)
        }
        let results = [
            ScanResultFixtures.make(loudness: -21.13, blocks: 60, truePeak: 0.31),
            ScanResultFixtures.make(loudness: -17.44, blocks: 45, truePeak: 0.62),
            ScanResultFixtures.make(loudness: -25.71, blocks: 90, truePeak: 0.18),
        ]
        let scanner = StubLoudnessScanner()
        for (track, result) in zip(tracks, results) {
            scanner.stub(result, forPath: track.filePath)
        }
        // pageSize 2 over 3 members guarantees the group is split: page 1 finds it
        // incomplete and must not pool, page 2 lands the last member and must then
        // write back to all three — including the two committed a page earlier.
        let service = makeScanService(database, scanner, pageSize: 2)

        service.start()
        await pollUntil { !service.isRunning }

        let expected = try #require(Self.oracle(results))
        var figures: [Double] = []
        for track in tracks {
            let trackId = try #require(track.id)
            let row = try requireLoudness(database, trackId: trackId)
            let figure = try #require(row.albumLUFS)
            figures.append(figure)
            #expect(row.albumPeak == 0.62)
        }
        let highest = try #require(figures.max())
        let lowest = try #require(figures.min())
        #expect(highest == lowest, "one UPDATE writes one figure to every member")
        #expect(abs(highest - expected) < 0.1, "pooled \(highest) vs oracle \(expected)")
    }

    @Test("a group with an undecodable member stays unpooled — the fail-closed denominator")
    func undecodableMemberLeavesTheGroupUnpooled() async throws {
        let database = try AppDatabase.makeEmpty()
        let albumId = try insertAlbum(database, title: "Broken")
        let good = try insertScanTrack(database, path: "/music/good.flac", albumId: albumId)
        let bad = try insertScanTrack(database, path: "/music/bad.flac", albumId: albumId)
        let goodId = try #require(good.id)
        let badId = try #require(bad.id)

        let measured = ScanResultFixtures.make(loudness: -23.02, blocks: 77, truePeak: 0.071)
        let scanner = StubLoudnessScanner()
        scanner.stub(measured, forPath: good.filePath)
        let service = makeScanService(database, scanner)

        service.start()
        await pollUntil { !service.isRunning }

        #expect(service.failedCount == 1)
        let row = try requireLoudness(database, trackId: goodId)
        let lufs = try #require(row.integratedLUFS)
        #expect(abs(lufs + 23.02) < 0.001, "the decodable member keeps its OWN measurement")
        #expect(row.truePeak == 0.071)
        #expect(row.albumLUFS == nil, "an incomplete group must never publish an album figure")
        #expect(row.albumPeak == nil)
        let failedRow = try fetchLoudness(database, trackId: badId)
        #expect(failedRow == nil, "a failed scan writes NO row — that absence is the denominator")
    }

    @Test("pooling reads stored histograms — a member is never re-decoded to pool it")
    func poolingNeverRedecodes() async throws {
        let database = try AppDatabase.makeEmpty()
        let albumId = try insertAlbum(database, title: "Streamed")
        let provider = PlanarBufferDecoderProvider()
        for index in 1 ... 2 {
            let path = "/music/p\(index).flac"
            try insertScanTrack(database, path: path, albumId: albumId)
            provider.register(
                ScanFixtures.stereoTone(dBFS: index == 1 ? -23 : -18, seconds: 1),
                forPath: path
            )
        }
        // pageSize 1 splits the album across two pages, so pooling MUST reach for
        // page 1's stored histogram when page 2 completes the group.
        let service = makeScanService(database, LoudnessScanner(decoderProvider: provider), pageSize: 1)

        service.start()
        await pollUntil { !service.isRunning }

        #expect(provider.openCount == 2, "exactly one open per member, none for pooling")
        let rows = try allLoudnessRows(database)
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.albumLUFS != nil })
    }

    @Test("a track with no albumId never receives album fields")
    func trackWithoutAlbumIsNeverPooled() async throws {
        let database = try AppDatabase.makeEmpty()
        let track = try insertScanTrack(database, path: "/music/loose.flac")
        let trackId = try #require(track.id)
        let scanner = StubLoudnessScanner()
        scanner.stub(ScanResultFixtures.quiet, forPath: track.filePath)
        let service = makeScanService(database, scanner)

        service.start()
        await pollUntil { !service.isRunning }

        let row = try requireLoudness(database, trackId: trackId)
        #expect(row.integratedLUFS != nil)
        #expect(row.albumLUFS == nil)
        #expect(row.albumPeak == nil)
    }

    @Test("a re-scanned member re-pools the group rather than leaving a stale figure")
    func rescanRepoolsTheGroup() async throws {
        let database = try AppDatabase.makeEmpty()
        let albumId = try insertAlbum(database, title: "Rewritten")
        let first = try insertScanTrack(database, path: "/music/r1.flac", albumId: albumId)
        let second = try insertScanTrack(database, path: "/music/r2.flac", albumId: albumId)
        let firstId = try #require(first.id)
        let secondId = try #require(second.id)

        let original = ScanResultFixtures.make(loudness: -23.02, blocks: 60, truePeak: 0.07)
        let scanner = StubLoudnessScanner()
        scanner.stub(original, forPath: first.filePath)
        scanner.stub(original, forPath: second.filePath)
        let firstPass = makeScanService(database, scanner)
        firstPass.start()
        await pollUntil { !firstPass.isRunning }
        let seeded = try requireLoudness(database, trackId: firstId)
        #expect(seeded.albumLUFS != nil)

        try simulateFileRewrite(database, trackId: secondId, newMtime: 999)
        let rescanned = ScanResultFixtures.make(loudness: -11.5, blocks: 60, truePeak: 0.94)
        let secondScanner = StubLoudnessScanner()
        secondScanner.stub(rescanned, forPath: second.filePath)
        let secondPass = makeScanService(database, secondScanner)

        secondPass.start()
        await pollUntil { !secondPass.isRunning }

        #expect(secondPass.progress.total == 1, "only the rewritten member is stale again")
        let expected = try #require(Self.oracle([original, rescanned]))
        let firstRow = try requireLoudness(database, trackId: firstId)
        let pooled = try #require(firstRow.albumLUFS)
        #expect(abs(pooled - expected) < 0.1, "the group re-pooled around the new measurement")
        #expect(firstRow.albumPeak == 0.94)
    }

    @Test("the histogram gate recomputation matches the raw-block path")
    func histogramPoolingMatchesRawBlocks() throws {
        let blocks = (0 ..< 400).map { -30.0 + Double($0 % 37) * 0.7 }
        let counts = BlockLoudnessHistogram.counts(forBlockLoudness: blocks)

        let viaHistogram = try #require(AlbumLoudnessPooling.integratedLoudness(ofPooledHistogram: counts))
        let viaBlocks = try #require(LoudnessGating.integratedLoudness(ofAbsoluteGatedBlocks: blocks))

        #expect(abs(viaHistogram - viaBlocks) < 0.06, "bin centres cost at most half a 0.1 dB bin")
    }

    @Test("an empty or misshapen histogram pools to nil rather than a fabricated figure")
    func emptyHistogramPoolsToNil() {
        let empty = [UInt32](repeating: 0, count: BlockLoudnessHistogram.binCount)
        #expect(AlbumLoudnessPooling.integratedLoudness(ofPooledHistogram: empty) == nil)
        #expect(AlbumLoudnessPooling.integratedLoudness(ofPooledHistogram: [1, 2, 3]) == nil)
        #expect(AlbumLoudnessPooling.maximumMembers == TrackLoudnessRepository.fetchLimit)
    }
}
