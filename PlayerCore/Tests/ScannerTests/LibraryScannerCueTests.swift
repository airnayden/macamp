// Scanner `.cue` sidecar import (todo 30): fresh scan, idempotent re-scan, the
// retain-and-hide upgrade path, and the filepath-identity audit's scanner site.
import Foundation
import GRDB
import Metadata
import Persistence
@testable import Services
import Testing

@Suite(.serialized)
struct LibraryScannerCueTests {
    // MARK: helpers

    private func summary(_ scanner: LibraryScanner, _ request: ScanRequest) async -> ScanSummary {
        var result = ScanSummary()
        for await event in scanner.events(for: request) {
            if case let .finished(value) = event {
                result = value
            }
        }
        return result
    }

    private func allRows(_ database: AppDatabase) throws -> [TrackRecord] {
        try database.writer.read { db in
            try TrackRecord.order(TrackRecord.Columns.cueStartFrame).fetchAll(db)
        }
    }

    // MARK: fresh scan

    @Test func freshCueScanCreatesOneRowPerSegmentAndNoWholeFileRow() async throws {
        let database = try AppDatabase.makeEmpty()
        let dir = try ScannerFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let album = try CueScanFixtures.writeAlbum(in: dir)
        let scanner = LibraryScanner(database: database, metadataReader: FakeMetadataReader())

        let result = await summary(scanner, .directory(dir))

        let rows = try allRows(database)
        #expect(result.added == 5)
        #expect(rows.count == 5)
        #expect(rows.allSatisfy { $0.filePath == album.audio.path })
        #expect(rows.map(\.cueStartFrame) == CueScanFixtures.startFrames)
        #expect(rows.allSatisfy { $0.cueSheetPath == album.sheet.path })
        #expect(rows.contains { $0.cueStartFrame == TrackRecord.wholeFileCueStartFrame } == false)
    }

    @Test func cueSheetIsNeverImportedAsATrackNorReadAsAudio() async throws {
        let database = try AppDatabase.makeEmpty()
        let dir = try ScannerFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try CueScanFixtures.writeAlbum(in: dir)
        let reader = CountingMetadataReader()
        let scanner = LibraryScanner(database: database, metadataReader: reader)

        _ = await summary(scanner, .directory(dir))

        let rows = try allRows(database)
        #expect(rows.contains { $0.filePath.hasSuffix(".cue") } == false)
        #expect(reader.readCount(forPathExtension: "cue") == 0)
    }

    @Test func fiveSegmentsCostExactlyOneTagReadOfTheirSharedAudioFile() async throws {
        let database = try AppDatabase.makeEmpty()
        let dir = try ScannerFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try CueScanFixtures.writeAlbum(in: dir)
        let reader = CountingMetadataReader()
        let scanner = LibraryScanner(database: database, metadataReader: reader)

        _ = await summary(scanner, .directory(dir))

        let rows = try allRows(database)
        #expect(rows.count == 5)
        #expect(reader.readCount(forPathExtension: "flac") == 1)
    }

    // MARK: field mapping

    @Test func cueTextWinsOverFileTagsWithTagsAsFallback() async throws {
        let database = try AppDatabase.makeEmpty()
        let dir = try ScannerFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try CueScanFixtures.writeAlbum(in: dir)
        let scanner = LibraryScanner(database: database, metadataReader: FakeMetadataReader())

        _ = await summary(scanner, .directory(dir))

        let rows = try allRows(database)
        #expect(rows.map(\.title) == CueScanFixtures.titles)
        #expect(rows[0].artistName == CueScanFixtures.firstTrackPerformer)
        #expect(rows[1].artistName == CueScanFixtures.discPerformer)
        #expect(rows.allSatisfy { $0.albumTitle == CueScanFixtures.discTitle })
        #expect(rows.allSatisfy { $0.genre == "Electronic" })
        #expect(rows.allSatisfy { $0.year == 1997 })
        #expect(rows.map(\.trackNumber) == [1, 2, 3, 4, 5])
        // Stream properties have no cue equivalent and come from the audio file.
        #expect(rows.allSatisfy { $0.sampleRate == 44100 })
    }

    @Test func segmentDurationsComeFromFrameRangeAndLastRunsToEndOfFile() async throws {
        let database = try AppDatabase.makeEmpty()
        let dir = try ScannerFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try CueScanFixtures.writeAlbum(in: dir)
        let scanner = LibraryScanner(database: database, metadataReader: FakeMetadataReader())

        _ = await summary(scanner, .directory(dir))

        let rows = try allRows(database)
        for (row, expected) in zip(rows, CueScanFixtures.expectedDurations) {
            #expect(abs((row.duration ?? -1) - expected) < 0.001)
        }
        #expect(rows.last?.cueEndFrame == nil)
        #expect(rows.first?.cueEndFrame == 2250)
    }

    // MARK: re-scan

    @Test func cueRescanIsIdempotentAndSkipsOnFingerprint() async throws {
        let database = try AppDatabase.makeEmpty()
        let dir = try ScannerFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try CueScanFixtures.writeAlbum(in: dir)
        let reader = CountingMetadataReader()
        let scanner = LibraryScanner(database: database, metadataReader: reader)
        _ = await summary(scanner, .directory(dir))
        let readsAfterFirstScan = reader.readURLs.count

        let second = await summary(scanner, .directory(dir))

        let rows = try allRows(database)
        #expect(second.added == 0)
        #expect(second.updated == 0)
        #expect(second.skipped == 5)
        #expect(rows.count == 5)
        #expect(reader.readURLs.count == readsAfterFirstScan)
    }

    /// FILEPATH-IDENTITY AUDIT — site 2 of 2 in scope:
    /// `LibraryScanner+Chunk.fetchExisting(paths:)` keyed its map by `filePath`, so
    /// five segments of one file collapsed to one entry and the other four were
    /// re-inserted on every scan. It is keyed by `(filePath, cueStartFrame)` now.
    @Test func fingerprintSkipLookupKeysOnFilePathAndCueStartFrame() async throws {
        let database = try AppDatabase.makeEmpty()
        let dir = try ScannerFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let album = try CueScanFixtures.writeAlbum(in: dir)
        let scanner = LibraryScanner(database: database, metadataReader: FakeMetadataReader())
        _ = await summary(scanner, .directory(dir))

        let existing = try scanner.fetchExisting(paths: [album.audio.path])

        #expect(existing.count == 5)
        #expect(Set(existing.keys.map(\.cueStartFrame)) == Set(CueScanFixtures.startFrames))
        #expect(existing.keys.allSatisfy { $0.filePath == album.audio.path })
    }

    // MARK: failure path

    @Test func cueNamingAMissingAudioFileImportsNothingAndCountsAFailure() async throws {
        let database = try AppDatabase.makeEmpty()
        let dir = try ScannerFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try CueScanFixtures.writeUnresolvedSheet(in: dir)
        let scanner = LibraryScanner(database: database, metadataReader: FakeMetadataReader())

        let result = await summary(scanner, .directory(dir))

        let rows = try allRows(database)
        #expect(result.failed == 1)
        #expect(result.added == 0)
        #expect(rows.isEmpty)
    }
}
