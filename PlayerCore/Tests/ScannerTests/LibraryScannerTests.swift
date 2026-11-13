// Behavioural tests for the resumable, batched ``LibraryScanner`` (Task 13).
import Foundation
import GRDB
import Metadata
import os
import Persistence
@testable import Services
import Testing

@Suite(.serialized)
struct LibraryScannerTests {
    // MARK: helpers

    private func collect(
        _ stream: AsyncStream<ScanEvent>
    ) async -> (progress: [ScanProgress], summary: ScanSummary) {
        var progress: [ScanProgress] = []
        var summary = ScanSummary()
        for await event in stream {
            switch event {
            case let .progress(value):
                progress.append(value)
            case let .finished(value):
                summary = value
            }
        }
        return (progress, summary)
    }

    private func trackCount(_ database: AppDatabase) throws -> Int {
        try database.writer.read { try TrackRecord.fetchCount($0) }
    }

    private func seedProfileStates(
        database: AppDatabase,
        trackId: Int64
    ) async throws {
        try await database.writer.write { db in
            var profile2 = ProfileRecord(
                name: "Profile 2",
                lastName: nil,
                bio: nil,
                avatarId: "waveform-vice",
                pinHash: nil,
                pinSalt: nil,
                createdAt: Date()
            )
            try profile2.insert(db)
        }

        try await database.writer.write { db in
            let state1 = ProfileTrackStateRecord(
                profileId: 1,
                trackId: trackId,
                isFavourite: true,
                playCount: 0,
                listenedCount: 0,
                customPosition: nil
            )
            try state1.insert(db)
            let state2 = ProfileTrackStateRecord(
                profileId: 2,
                trackId: trackId,
                isFavourite: true,
                playCount: 0,
                listenedCount: 0,
                customPosition: nil
            )
            try state2.insert(db)
        }
    }

    // MARK: import + progress

    @Test func importsDirectoryEmittingProgressAndSummary() async throws {
        let database = try AppDatabase.makeEmpty()
        let dir = try ScannerFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        for index in 0 ..< 6 {
            try ScannerFixtures.writeFile(in: dir, name: "track_\(index).flac")
        }
        for index in 0 ..< 4 {
            try ScannerFixtures.writeFile(in: dir, name: "song_\(index).mp3")
        }
        let scanner = LibraryScanner(database: database, metadataReader: FakeMetadataReader())

        let (progress, summary) = await collect(scanner.events(for: .directory(dir)))

        #expect(!progress.isEmpty)
        #expect(progress.last?.processed == 10)
        #expect(progress.last?.total == 10)
        #expect(summary == ScanSummary(added: 10, updated: 0, skipped: 0, failed: 0))
        try #expect(trackCount(database) == 10)
    }

    // MARK: idempotent re-scan

    @Test func rescanSkipsUnchangedFiles() async throws {
        let database = try AppDatabase.makeEmpty()
        let dir = try ScannerFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        for index in 0 ..< 8 {
            try ScannerFixtures.writeFile(in: dir, name: "t\(index).flac")
        }
        let scanner = LibraryScanner(database: database, metadataReader: FakeMetadataReader())

        let first = await scanner.scan(.directory(dir))
        #expect(first == ScanSummary(added: 8))

        let second = await scanner.scan(.directory(dir))
        #expect(second == ScanSummary(skipped: 8))
        try #expect(trackCount(database) == 8)
    }

    // MARK: update preserves identity

    @Test func changedFileUpdatesPreservingIdentity() async throws {
        let database = try AppDatabase.makeEmpty()
        let dir = try ScannerFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try ScannerFixtures.writeFile(in: dir, name: "one.flac", bytes: 16)
        let scanner = LibraryScanner(database: database, metadataReader: FakeMetadataReader())

        _ = await scanner.scan(.directory(dir))
        let beforeRow = try await database.writer.read { try TrackRecord.fetchOne($0) }
        let original = try #require(beforeRow)

        // Grow the file so its fingerprint (size + mtime) differs.
        try Data(repeating: 0xCD, count: 4096).write(to: url)
        let summary = await scanner.scan(.directory(dir))

        #expect(summary == ScanSummary(updated: 1))
        let afterRow = try await database.writer.read { try TrackRecord.fetchOne($0) }
        let updated = try #require(afterRow)
        #expect(updated.id == original.id)
        #expect(updated.dateAdded == original.dateAdded)
        #expect(updated.fileSize == 4096)
        try #expect(trackCount(database) == 1)
    }

    // MARK: failure isolation

    @Test func unreadableFileCountsAsFailure() async throws {
        let database = try AppDatabase.makeEmpty()
        let dir = try ScannerFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try ScannerFixtures.writeFile(in: dir, name: "a.flac")
        try ScannerFixtures.writeFile(in: dir, name: "b.mp3")
        try ScannerFixtures.writeFile(in: dir, name: "bad.ogg")
        let scanner = LibraryScanner(
            database: database,
            metadataReader: FakeMetadataReader(unsupportedExtensions: ["ogg"])
        )

        let summary = await scanner.scan(.directory(dir))

        #expect(summary.added == 2)
        #expect(summary.failed == 1)
        #expect(summary.skipped == 0)
        #expect(summary.updated == 0)
        try #expect(trackCount(database) == 2)
    }

    // MARK: batched inserts keep the transaction count constant

    @Test func batchedInsertsKeepTransactionCountConstant() async throws {
        let (smallDB, smallTrace) = try ScannerFixtures.makeTracedDatabase()
        let smallScanner = LibraryScanner(database: smallDB, metadataReader: FakeMetadataReader())
        _ = await smallScanner.scan(.manifest(ScannerFixtures.syntheticCandidates(20)))
        let smallBegins = smallTrace.count(matching: "BEGIN")

        let (largeDB, largeTrace) = try ScannerFixtures.makeTracedDatabase()
        let largeScanner = LibraryScanner(database: largeDB, metadataReader: FakeMetadataReader())
        _ = await largeScanner.scan(.manifest(ScannerFixtures.syntheticCandidates(400)))
        let largeBegins = largeTrace.count(matching: "BEGIN")

        try #expect(trackCount(smallDB) == 20)
        try #expect(trackCount(largeDB) == 400)
        #expect(smallBegins > 0)
        #expect(smallBegins == largeBegins) // independent of candidate count
        #expect(largeBegins <= 8) // batched, never per-file
    }

    // MARK: cancellation is resumable

    @Test func cancellationPersistsCommittedChunksThenResumes() async throws {
        let database = try AppDatabase.makeEmpty()
        let candidates = ScannerFixtures.syntheticCandidates(30)
        let reader = GatedMetadataReader(base: FakeMetadataReader.defaultMetadata, permits: 10)
        let scanner = LibraryScanner(database: database, metadataReader: reader, chunkSize: 10, maxConcurrency: 4)

        // The producer commits chunk 1 (10 permits) then stalls in chunk 2's gated reads.
        let consumer = Task {
            for await _ in scanner.events(for: .manifest(candidates)) {}
        }
        var waited = 0
        while try trackCount(database) < 10, waited < 400 {
            try await Task.sleep(for: .milliseconds(5))
            waited += 1
        }

        // Cancelling the consuming task fires onTermination(.cancelled) → scan-task cancel.
        consumer.cancel()
        _ = await consumer.value
        try? await Task.sleep(for: .milliseconds(50))

        try #expect(trackCount(database) == 10) // only the first committed chunk survived

        let resumeScanner = LibraryScanner(database: database, metadataReader: FakeMetadataReader())
        let summary = await resumeScanner.scan(.manifest(candidates))
        #expect(summary.added == 20)
        #expect(summary.skipped == 10)
        try #expect(trackCount(database) == 30)
    }

    // MARK: profile state survives re-scan

    @Test func profileTrackStatePreservedAcrossRescan() async throws {
        let database = try AppDatabase.makeEmpty()
        let dir = try ScannerFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try ScannerFixtures.writeFile(in: dir, name: "track.flac", bytes: 16)
        let scanner = LibraryScanner(database: database, metadataReader: FakeMetadataReader())

        // First scan: add the track
        _ = await scanner.scan(.directory(dir))
        let trackId = try await database.writer.read { db in
            try TrackRecord.fetchOne(db)?.id
        }
        let trackId64 = try #require(trackId)

        // Seed profile records and state
        try await seedProfileStates(database: database, trackId: trackId64)

        // Verify state was inserted
        let statesBefore = try await database.writer.read { db in
            try ProfileTrackStateRecord.filter(ProfileTrackStateRecord.Columns.trackId == trackId64).fetchAll(db)
        }
        #expect(statesBefore.count == 2)
        // swiftformat:disable:next preferKeyPath
        #expect(statesBefore.allSatisfy { $0.isFavourite })

        // Modify file to trigger an update
        try Data(repeating: 0xCD, count: 4096).write(to: url)

        // Re-scan: should update the track but preserve its id
        let summary = await scanner.scan(.directory(dir))
        #expect(summary.updated == 1)

        // Verify track id is unchanged
        let trackAfter = try await database.writer.read { db in
            try TrackRecord.fetchOne(db)
        }
        let trackAfter64 = try #require(trackAfter?.id)
        #expect(trackAfter64 == trackId64)

        // Verify profile state is intact (scanner doesn't touch profileTrackState)
        let statesAfter = try await database.writer.read { db in
            try ProfileTrackStateRecord.filter(ProfileTrackStateRecord.Columns.trackId == trackId64).fetchAll(db)
        }
        #expect(statesAfter.count == 2)
        // swiftformat:disable:next preferKeyPath
        #expect(statesAfter.allSatisfy { $0.isFavourite })
    }

    // MARK: excluded directory (instrumental cache)

    @Test func excludesInjectedDirectoryFromWalk() async throws {
        let root = try ScannerFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0 ..< 3 {
            try ScannerFixtures.writeFile(in: root, name: "keep_\(index).flac")
        }
        let cacheDir = root.appendingPathComponent("Instrumentals", isDirectory: true)
        let nested = cacheDir.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        for index in 0 ..< 5 {
            try ScannerFixtures.writeFile(in: cacheDir, name: "cached_\(index).m4a")
        }
        try ScannerFixtures.writeFile(in: nested, name: "deep.m4a")

        // Control: with no exclusion every file imports, proving the cache files are
        // valid importable audio — so a 0-import result is caused by the exclusion.
        let controlDB = try AppDatabase.makeEmpty()
        let control = LibraryScanner(database: controlDB, metadataReader: FakeMetadataReader())
        #expect(await control.scan(.directory(root)) == ScanSummary(added: 9))

        let database = try AppDatabase.makeEmpty()
        let scanner = LibraryScanner(
            database: database,
            metadataReader: FakeMetadataReader(),
            excludedDirectories: [cacheDir]
        )
        let summary = await scanner.scan(.directory(root))

        #expect(summary == ScanSummary(added: 3))
        try #expect(trackCount(database) == 3)
        let importedPaths = try await database.writer.read { db in
            try TrackRecord.fetchAll(db).map(\.filePath)
        }
        #expect(importedPaths.allSatisfy { !$0.contains("/Instrumentals/") })
    }

    // MARK: dynamic exclusion provider (evaluated at scan time)

    @Test func providerFlipHonoredOnNextScan() async throws {
        let root = try ScannerFixtures.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0 ..< 3 {
            try ScannerFixtures.writeFile(in: root, name: "keep_\(index).flac")
        }
        let cacheDir = root.appendingPathComponent("Instrumentals", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        for index in 0 ..< 4 {
            try ScannerFixtures.writeFile(in: cacheDir, name: "cached_\(index).m4a")
        }

        let excluded = OSAllocatedUnfairLock<[URL]>(initialState: [cacheDir])
        let database = try AppDatabase.makeEmpty()
        let scanner = LibraryScanner(
            database: database,
            metadataReader: FakeMetadataReader(),
            excludedDirectories: { excluded.withLock { $0 } }
        )

        // First scan: the provider excludes the cache dir, so only the 3 keep files import.
        #expect(await scanner.scan(.directory(root)) == ScanSummary(added: 3))

        // Flip the provider to exclude nothing; the SAME scanner honors it next scan.
        excluded.withLock { $0 = [] }
        let summary = await scanner.scan(.directory(root))

        #expect(summary == ScanSummary(added: 4, skipped: 3))
        try #expect(trackCount(database) == 7)
    }
}
