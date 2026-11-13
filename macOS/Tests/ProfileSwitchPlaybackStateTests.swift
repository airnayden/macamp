import AudioEngine
import Foundation
@testable import MacAMP
import Models
import Persistence
import Services
import Testing
import ViewModels

@MainActor
@Suite("ProfileSwitchPlaybackStateTests", .serialized)
struct ProfileSwitchPlaybackStateTests {
    @Test("A to B to A restores A track, position, and source without auto-play")
    func roundTripRestoresOutgoingProfile() async throws {
        let harness = try ProfileSwitchPlaybackHarness(debounceInterval: .seconds(10))
        defer { harness.cancelPending() }

        harness.replaceQueue(harness.profileATracks, startingAt: 1, source: .playlist(id: 42))
        harness.coordinator.seek(to: 31.25)

        await harness.switchProfile(to: harness.profileBID)
        #expect(harness.coordinator.current == nil)

        harness.replaceQueue(harness.profileBTracks, startingAt: 0, source: .favourites)
        harness.coordinator.seek(to: 8.5)
        await harness.switchProfile(to: ProfileRecord.guestID)

        #expect(harness.coordinator.current?.filePath == harness.profileATracks[1].filePath)
        #expect(harness.coordinator.state.playback != .playing)
        #expect(abs(harness.coordinator.snapshot().position - 31.25) < 0.001)
        #expect(harness.identity.source == .playlist(id: 42))
    }

    @Test("an in-flight A debounce never writes A playback state under B")
    func pendingDebounceCannotCrossProfiles() async throws {
        let harness = try ProfileSwitchPlaybackHarness(debounceInterval: .milliseconds(120))
        defer { harness.cancelPending() }

        harness.replaceQueue(harness.profileATracks, startingAt: 2, source: .playlist(id: 7))
        harness.coordinator.seek(to: 19.5)
        await harness.switchProfile(to: harness.profileBID)
        try await Task.sleep(for: .milliseconds(220))

        let profileARow = try #require(await harness.record(for: ProfileRecord.guestID))
        let profileASnapshot = try harness.decodeSnapshot(profileARow)
        let profileASource = try harness.decodeSource(profileARow)
        let profileBRow = try await harness.record(for: harness.profileBID)
        #expect(profileASnapshot.currentID == harness.profileATracks[2].id)
        #expect(profileASnapshot.position == 19.5)
        #expect(profileASource == .playlist(id: 7))
        #expect(profileBRow == nil)
    }

    @Test("switching profiles restores the source container in the live sidebar")
    func switchingProfilesRestoresLiveSidebar() async throws {
        let harness = try ProfileSwitchPlaybackHarness(debounceInterval: .seconds(10))
        defer { harness.cancelPending() }
        harness.navigation.sidebar = .fixed(.albums)
        harness.replaceQueue(harness.profileATracks, startingAt: 0, source: .favourites)
        try await harness.seed(
            profileId: harness.profileBID,
            tracks: harness.profileBTracks,
            source: .playlist(id: 84)
        )

        await harness.switchProfile(to: harness.profileBID)
        #expect(harness.navigation.sidebar == .playlist(id: 84))

        await harness.switchProfile(to: ProfileRecord.guestID)
        #expect(harness.navigation.sidebar == .fixed(.favourites))
    }

    @Test("a node-less restored source preserves the incoming profile's sidebar")
    func nodeLessSourceDoesNotTouchLiveSidebar() async throws {
        let harness = try ProfileSwitchPlaybackHarness(debounceInterval: .seconds(10))
        defer { harness.cancelPending() }
        let incomingSelection = SidebarDestination.fixed(.artists)
        harness.sidebarStore(for: harness.profileBID).save(incomingSelection)
        harness.navigation.sidebar = .fixed(.albums)
        try await harness.seed(
            profileId: harness.profileBID,
            tracks: harness.profileBTracks,
            source: .search
        )

        await harness.switchProfile(to: harness.profileBID)

        #expect(harness.navigation.sidebar == incomingSelection)
        #expect(harness.identity.source == .search)
    }
}

@MainActor
private final class ProfileSwitchPlaybackHarness {
    let database: AppDatabase
    let coordinator: PlaybackCoordinator
    let identity = ProfileSwitchPlaybackIdentity()
    let repository: ProfilePlaybackStateRepository
    let persister: PlaybackStatePersister
    let navigation: NavigationModel
    let profileBID: Int64
    let profileATracks = ["a-first", "a-second", "a-third"].map { (name: String) in
        TrackRef(filePath: "/fixtures/profile-a/\(name).fake", title: name, availability: .present)
    }

    let profileBTracks = ["b-first", "b-second"].map { (name: String) in
        TrackRef(filePath: "/fixtures/profile-b/\(name).fake", title: name, availability: .present)
    }

    private var restoreTask: Task<Void, Never>?
    private let sidebarSuiteName: String

    private lazy var orchestrator = ProfileSwitchOrchestrator(
        activeProfileId: ProfileRecord.guestID,
        cancelPendingPlaybackSave: { [weak self] in self?.persister.cancelPending() },
        flushPlaybackState: { [weak self] profileId in
            self?.persister.flushNow(profileId: profileId)
        },
        restorePlaybackState: { [weak self] profileId in
            self?.scheduleRestore(for: profileId)
        },
        stopAndClearPlayback: { [weak self] in self?.coordinator.removeAll() },
        rescope: { _ in },
        restartObservations: {},
        currentRootPaths: { [] },
        runScanAndReconcile: {}
    )

    init(debounceInterval: Duration) throws {
        let database = try AppDatabase.makeEmpty()
        let engine = FakePlaybackEngine(decoderProvider: FakeDecoderProvider(duration: 100))
        let coordinator = PlaybackCoordinator(engine: engine)
        let repository = ProfilePlaybackStateRepository(database)
        let profile = try ProfileRepository(database).create(ProfileRecord(name: "Profile B"))
        let sidebarSuiteName = "com.example.macamp.tests.profile-switch-sidebar.\(UUID().uuidString)"
        guard let profileBID = profile.id else {
            throw ProfileSwitchPlaybackHarnessError.missingProfileID
        }

        self.database = database
        self.coordinator = coordinator
        self.repository = repository
        self.profileBID = profileBID
        self.sidebarSuiteName = sidebarSuiteName
        navigation = NavigationModel(store: SidebarSelectionStore(
            profileId: ProfileRecord.guestID,
            suiteName: sidebarSuiteName
        ))
        coordinator.playbackSourceDidChange = { [identity] source in
            identity.source = source
        }
        persister = PlaybackStatePersister(
            coordinator: coordinator,
            repository: repository,
            databaseWriter: database.writer,
            profileId: { [identity] in identity.profileId },
            currentSource: { [identity] in identity.source },
            debounceInterval: debounceInterval
        )
    }

    func replaceQueue(_ tracks: [TrackRef], startingAt index: Int, source: PlaybackSource) {
        coordinator.setQueue(tracks, startingAt: index, source: source)
    }

    func switchProfile(to profileId: Int64) async {
        // ProfileService.activate updates activeProfile before firing its change seam.
        identity.profileId = profileId
        navigation.resetForProfileSwitch(profileId: profileId, folderOwnership: .none)
        orchestrator.handleSwitch(toProfileId: profileId)
        await restoreTask?.value
    }

    func cancelPending() {
        restoreTask?.cancel()
        persister.cancelPending()
        UserDefaults().removePersistentDomain(forName: sidebarSuiteName)
    }

    func sidebarStore(for profileId: Int64) -> SidebarSelectionStore {
        SidebarSelectionStore(profileId: profileId, suiteName: sidebarSuiteName)
    }

    func seed(profileId: Int64, tracks: [TrackRef], source: PlaybackSource) async throws {
        let snapshot = CoordinatorSnapshot(
            entries: tracks,
            order: tracks.map(\.id),
            currentID: tracks.first?.id,
            shuffle: false,
            repeatMode: .off,
            position: 12.5
        )
        let snapshotData = try JSONEncoder().encode(snapshot)
        let sourceData = try JSONEncoder().encode(source)
        let snapshotJson = try #require(String(data: snapshotData, encoding: .utf8))
        let sourceJson = try #require(String(data: sourceData, encoding: .utf8))
        try await repository.upsert(
            for: profileId,
            snapshotJson: snapshotJson,
            sourceJson: sourceJson,
            savedAt: 1
        )
    }

    func record(for profileId: Int64) async throws -> ProfilePlaybackStateRecord? {
        try await repository.fetch(for: profileId)
    }

    func decodeSnapshot(_ record: ProfilePlaybackStateRecord) throws -> CoordinatorSnapshot {
        try JSONDecoder().decode(CoordinatorSnapshot.self, from: Data(record.snapshotJson.utf8))
    }

    func decodeSource(_ record: ProfilePlaybackStateRecord) throws -> PlaybackSource? {
        guard let sourceJson = record.sourceJson else { return nil }
        return try JSONDecoder().decode(PlaybackSource.self, from: Data(sourceJson.utf8))
    }

    private func scheduleRestore(for profileId: Int64) {
        restoreTask?.cancel()
        let identity = identity
        let navigation = navigation
        let restorer = PlaybackStateRestorer(
            repository: repository,
            rootRepository: LibraryRootRepository(database),
            coordinator: coordinator,
            sidebarStore: sidebarStore(for: profileId),
            sourceDidRestore: { [identity] source in identity.source = source },
            shouldApply: { identity.profileId == profileId && !Task.isCancelled }
        )
        restoreTask = Task { @MainActor in
            guard identity.profileId == profileId else { return }
            identity.source = nil
            guard await restorer.restore(profileId: profileId), identity.profileId == profileId else { return }
            navigation.restoreSidebarForProfileSwitch(profileId: profileId)
        }
    }
}

@MainActor
private final class ProfileSwitchPlaybackIdentity {
    var profileId = ProfileRecord.guestID
    var source: PlaybackSource?
}

private enum ProfileSwitchPlaybackHarnessError: Error {
    case missingProfileID
}
