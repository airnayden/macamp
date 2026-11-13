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

@MainActor
@Suite("PlaybackStatePersisterTests", .serialized)
struct PlaybackStatePersisterTests {
    @Test("debounce coalesces rapid track changes to one write")
    func debounceCoalescesRapidTrackChanges() async throws {
        let harness = try PlaybackStateTestHarness(debounceInterval: .milliseconds(40))
        defer { harness.persister.cancelPending() }
        let initialChanges = try harness.changeCount()

        harness.replaceQueue(source: .librarySection("allTracks"))
        harness.coordinator.play(at: 1)
        harness.coordinator.play(at: 2)
        _ = try #require(await harness.waitForRecord(for: ProfileRecord.guestID))

        #expect(try harness.changeCount() - initialChanges == 1)
    }

    @Test("pause writes immediately without waiting for the debounce")
    func pauseWritesImmediately() async throws {
        let harness = try PlaybackStateTestHarness(debounceInterval: .seconds(10))
        defer { harness.persister.cancelPending() }
        harness.replaceQueue(source: .favourites)
        harness.coordinator.seek(to: 24.5)

        harness.coordinator.pause()

        let row = try #require(await harness.waitForRecord(for: ProfileRecord.guestID))
        let snapshot = try harness.decodeSnapshot(row)
        #expect(snapshot.position == 24.5)
    }

    @Test("stop writes immediately without waiting for the debounce")
    func stopWritesImmediately() async throws {
        let harness = try PlaybackStateTestHarness(debounceInterval: .seconds(10))
        defer { harness.persister.cancelPending() }
        harness.replaceQueue(source: .favourites)

        harness.coordinator.stop()

        let row = try #require(await harness.waitForRecord(for: ProfileRecord.guestID))
        let snapshot = try harness.decodeSnapshot(row)
        #expect(snapshot.position == 0)
    }

    @Test("a debounce captures its profile before a simulated switch")
    func debounceKeepsScheduledProfile() async throws {
        let harness = try PlaybackStateTestHarness(debounceInterval: .milliseconds(50))
        defer { harness.persister.cancelPending() }
        let secondProfile = try ProfileRepository(harness.database).create(ProfileRecord(name: "Second"))
        let secondProfileID = try #require(secondProfile.id)

        harness.replaceQueue(source: .playlist(id: 9))
        harness.identity.profileId = secondProfileID

        #expect(try await harness.waitForRecord(for: ProfileRecord.guestID) != nil)
        #expect(try await harness.record(for: secondProfileID) == nil)
    }

    @Test("snapshot JSON round-trips through CoordinatorSnapshot")
    func snapshotJSONRoundTrips() async throws {
        let harness = try PlaybackStateTestHarness(debounceInterval: .seconds(10))
        defer { harness.persister.cancelPending() }
        harness.replaceQueue(source: .playlist(id: 42))
        harness.coordinator.play(at: 1)
        harness.coordinator.seek(to: 31.25)
        harness.coordinator.pause()
        let expected = harness.coordinator.snapshot()

        let row = try #require(await harness.waitForRecord(for: ProfileRecord.guestID))
        #expect(try harness.decodeSnapshot(row) == expected)
        #expect(try harness.decodeSource(row) == .playlist(id: 42))
    }

    @Test("snapshot JSON never persists the instrumental cache directory")
    func snapshotExcludesInstrumentalCachePath() async throws {
        let harness = try PlaybackStateTestHarness(debounceInterval: .seconds(10))
        defer { harness.persister.cancelPending() }
        harness.replaceQueue(source: .karaokeReady)
        harness.coordinator.pause()

        let row = try #require(await harness.waitForRecord(for: ProfileRecord.guestID))
        let cachePath = try #require(InstrumentalCacheLocation.defaultDirectory()?.path)
        #expect(!row.snapshotJson.contains(cachePath))
        #expect(try harness.decodeSnapshot(row).entries.count == harness.tracks.count)
    }

    @Test("termination supersedes a pending debounce with the live engine position")
    func terminationFlushUsesLivePosition() async throws {
        let harness = try PlaybackStateTestHarness(debounceInterval: .milliseconds(120))
        defer { harness.persister.cancelPending() }
        let initialChanges = try harness.changeCount()
        harness.replaceQueue(source: .search)
        harness.coordinator.seek(to: 47.75)

        await harness.persister.flushAtTermination()

        let row = try #require(await harness.record(for: ProfileRecord.guestID))
        #expect(try harness.decodeSnapshot(row).position == 47.75)
        #expect(try harness.changeCount() - initialChanges == 1)
    }
}

@MainActor
final class PlaybackStateTestHarness {
    let database: AppDatabase
    let coordinator: PlaybackCoordinator
    let identity: PlaybackPersistenceIdentity
    let repository: ProfilePlaybackStateRepository
    let persister: PlaybackStatePersister
    let tracks: [TrackRef]

    private static let defaultTracks = ["first", "second", "third"].map { (name: String) in
        TrackRef(filePath: "/fixtures/\(name).fake", title: name, availability: .present)
    }

    private let suiteName = "com.example.macamp.tests.playback-state.\(UUID().uuidString)"
    private lazy var sidebarStore = SidebarSelectionStore(
        profileId: ProfileRecord.guestID,
        suiteName: suiteName,
        key: "sidebar-selection"
    )

    lazy var restorer = PlaybackStateRestorer(
        repository: repository,
        rootRepository: LibraryRootRepository(database),
        coordinator: coordinator,
        sidebarStore: sidebarStore,
        sourceDidRestore: { [identity] source in identity.source = source }
    )

    convenience init(debounceInterval: Duration) throws {
        try self.init(
            database: AppDatabase.makeEmpty(),
            tracks: Self.defaultTracks,
            debounceInterval: debounceInterval
        )
    }

    init(database: AppDatabase, tracks: [TrackRef], debounceInterval: Duration) {
        let coordinator = PlaybackCoordinator(
            engine: FakePlaybackEngine(decoderProvider: FakeDecoderProvider(duration: 100))
        )
        let identity = PlaybackPersistenceIdentity()
        let repository = ProfilePlaybackStateRepository(database)
        coordinator.playbackSourceDidChange = { identity.source = $0 }

        self.database = database
        self.coordinator = coordinator
        self.identity = identity
        self.repository = repository
        self.tracks = tracks
        persister = PlaybackStatePersister(
            coordinator: coordinator,
            repository: repository,
            databaseWriter: database.writer,
            profileId: { identity.profileId },
            currentSource: { identity.source },
            debounceInterval: debounceInterval
        )
    }

    func replaceQueue(source: PlaybackSource, startingAt index: Int = 0) {
        coordinator.setQueue(tracks, startingAt: index, source: source)
    }

    func changeCount() throws -> Int {
        try database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT total_changes()") ?? 0
        }
    }

    func record(for profileId: Int64) async throws -> ProfilePlaybackStateRecord? {
        try await repository.fetch(for: profileId)
    }

    func waitForRecord(
        for profileId: Int64,
        timeout: Duration = .seconds(2)
    ) async throws -> ProfilePlaybackStateRecord? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let record = try await record(for: profileId) {
                return record
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try await record(for: profileId)
    }

    func decodeSnapshot(_ record: ProfilePlaybackStateRecord) throws -> CoordinatorSnapshot {
        try JSONDecoder().decode(CoordinatorSnapshot.self, from: Data(record.snapshotJson.utf8))
    }

    func decodeSource(_ record: ProfilePlaybackStateRecord) throws -> PlaybackSource? {
        guard let sourceJson = record.sourceJson else { return nil }
        return try JSONDecoder().decode(PlaybackSource.self, from: Data(sourceJson.utf8))
    }

    func cleanUp() {
        persister.cancelPending()
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
final class PlaybackPersistenceIdentity {
    var profileId = ProfileRecord.guestID
    var source: PlaybackSource?
}
