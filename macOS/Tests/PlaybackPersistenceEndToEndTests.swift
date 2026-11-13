import AppKit
import AudioEngine
import Foundation
import GRDB
@testable import MacAMP
import Models
import Persistence
import Separation
import Services
import Testing

extension PlaybackStatePersisterTests {
    @Test("debounced and pause saves execute the real repository write off main")
    func asynchronousSavePathsWriteOffMain() async throws {
        let database = try makeMainThreadRejectingDatabase()
        let harness = PlaybackStateTestHarness(
            database: database,
            tracks: makeTracks(count: 3),
            debounceInterval: .milliseconds(30)
        )
        defer { harness.cleanUp() }

        harness.replaceQueue(source: .librarySection("allTracks"))
        _ = try #require(await harness.waitForRecord(for: ProfileRecord.guestID))

        harness.coordinator.seek(to: 18.25)
        harness.coordinator.pause()
        let pausedRow = try #require(await waitForPosition(18.25, harness: harness))

        #expect(try harness.decodeSnapshot(pausedRow).position == 18.25)
    }

    @Test("50k-entry termination flush stays under one second or persists the exact 20k fallback")
    func fiftyThousandEntryTerminationFlushIsBounded() async throws {
        let entryCount = 50000
        let terminationEntryLimit = 20000
        let tracks = makeTracks(count: entryCount)
        let harness = try PlaybackStateTestHarness(
            database: AppDatabase.makeEmpty(),
            tracks: tracks,
            debounceInterval: .seconds(60)
        )
        defer { harness.cleanUp() }
        let currentIndex = entryCount / 2
        harness.replaceQueue(source: .playlist(id: 50000), startingAt: currentIndex)

        let clock = ContinuousClock()
        let startedAt = clock.now
        harness.persister.flushNow(profileId: ProfileRecord.guestID)
        let elapsed = startedAt.duration(to: clock.now)

        let row = try #require(await harness.record(for: ProfileRecord.guestID))
        let restored = try harness.decodeSnapshot(row)
        #expect(restored.currentID == tracks[currentIndex].id)
        #expect(try harness.decodeSource(row) == .playlist(id: 50000))
        if elapsed < .seconds(1) {
            #expect(restored.entries.count == entryCount)
        } else {
            #expect(restored.entries.count == terminationEntryLimit)
        }
    }

    @Test("full queue/source/position cycle survives termination and a fresh environment")
    func fullPersistenceCycleRestoresFreshEnvironment() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macamp-playback-cycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let tracks = makeTracks(count: 4)
        let source = PlaybackSource.playlist(id: 734)
        let expectedPosition = 63.25

        let savingHarness = try PlaybackStateTestHarness(
            database: makeOnDiskDatabase(at: databaseURL),
            tracks: tracks,
            debounceInterval: .seconds(60)
        )
        defer { savingHarness.cleanUp() }
        savingHarness.replaceQueue(source: source)
        savingHarness.coordinator.play(at: 2)
        savingHarness.coordinator.seek(to: expectedPosition)
        savingHarness.coordinator.pause()
        await savingHarness.persister.flushAtTermination()

        let row = try #require(await savingHarness.record(for: ProfileRecord.guestID))
        let cachePath = try #require(InstrumentalCacheLocation.defaultDirectory()?.path)
        #expect(!row.snapshotJson.contains(cachePath))
        #expect(!(row.sourceJson ?? "").contains(cachePath))

        let restoringHarness = try PlaybackStateTestHarness(
            database: makeOnDiskDatabase(at: databaseURL),
            tracks: tracks,
            debounceInterval: .seconds(60)
        )
        defer { restoringHarness.cleanUp() }

        #expect(await restoringHarness.restorer.restore(profileId: ProfileRecord.guestID))
        #expect(restoringHarness.coordinator.state.current?.id == tracks[2].id)
        #expect(restoringHarness.coordinator.state.playback != .playing)
        #expect(abs(restoringHarness.coordinator.snapshot().position - expectedPosition) <= 0.5)
        #expect(restoringHarness.identity.source == source)
    }
}

private func makeTracks(count: Int) -> [TrackRef] {
    var tracks: [TrackRef] = []
    tracks.reserveCapacity(count)
    for index in 0 ..< count {
        tracks.append(
            TrackRef(
                filePath: "/fixtures/persistence/track-\(index).fake",
                title: "Track \(index)",
                availability: .present
            )
        )
    }
    return tracks
}

@MainActor
private func waitForPosition(
    _ expectedPosition: TimeInterval,
    harness: PlaybackStateTestHarness
) async throws -> ProfilePlaybackStateRecord? {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline {
        if let row = try await harness.record(for: ProfileRecord.guestID),
           try harness.decodeSnapshot(row).position == expectedPosition
        {
            return row
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    return try await harness.record(for: ProfileRecord.guestID)
}

private func makeMainThreadRejectingDatabase() throws -> AppDatabase {
    let isMainThread = DatabaseFunction(
        "test_is_main_thread",
        argumentCount: 0,
        pure: false
    ) { _ in
        Thread.isMainThread ? 1 : 0
    }
    var configuration = Configuration()
    configuration.prepareDatabase { database in
        database.add(function: isMainThread)
    }
    let writer = try DatabaseQueue(configuration: configuration)
    let database = try AppDatabase(writer)
    try database.writer.write { database in
        try database.execute(sql: """
        CREATE TRIGGER reject_main_thread_playback_insert
        BEFORE INSERT ON profilePlaybackState
        WHEN test_is_main_thread() = 1
        BEGIN
            SELECT RAISE(ABORT, 'main-thread playback-state insert');
        END;
        CREATE TRIGGER reject_main_thread_playback_update
        BEFORE UPDATE ON profilePlaybackState
        WHEN test_is_main_thread() = 1
        BEGIN
            SELECT RAISE(ABORT, 'main-thread playback-state update');
        END;
        """)
    }
    return database
}

private func makeOnDiskDatabase(at url: URL) throws -> AppDatabase {
    var configuration = Configuration()
    configuration.journalMode = .wal
    return try AppDatabase(DatabasePool(path: url.path, configuration: configuration))
}
