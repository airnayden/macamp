import AudioEngine
import Foundation
@testable import MacAMP
import Models
import Persistence
import Services
import Testing
import ViewModels

@MainActor
@Suite("Playback launch restore", .serialized)
struct PlaybackLaunchRestoreTests {
    @Test("a cancelled launch task still restores the last played track")
    func cancelledLaunchTaskRestoresLastPlayedTrack() async throws {
        let environment = AppEnvironment.preview()
        let track = TrackRef(
            filePath: "/fixtures/cancelled-launch.fake",
            title: "Cancelled Launch",
            availability: .present
        )
        let expectedPosition = 0.5
        let snapshot = CoordinatorSnapshot(
            entries: [track],
            order: [track.id],
            currentID: track.id,
            shuffle: false,
            repeatMode: .off,
            position: expectedPosition
        )
        let snapshotData = try JSONEncoder().encode(snapshot)
        let snapshotJson = try #require(String(data: snapshotData, encoding: .utf8))
        try await ProfilePlaybackStateRepository(environment.database).upsert(
            for: ProfileRecord.guestID,
            snapshotJson: snapshotJson,
            sourceJson: nil,
            savedAt: 1
        )
        let controller = StateRestorationController(environment: environment, settings: AppSettings())

        let launchTask = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await controller.restore()
        }
        await launchTask.value

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while abs(environment.coordinator.snapshot().position - expectedPosition) > 0.1,
              clock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(environment.coordinator.state.current == track)
        #expect(environment.coordinator.state.playback != .playing)
        #expect(abs(environment.coordinator.snapshot().position - expectedPosition) <= 0.1)
    }

    @Test("restored container overrides last viewed before navigation initializes")
    func restoredContainerWinsLaunchSelection() async throws {
        let harness = try LaunchRestoreHarness()
        defer { harness.cleanUp() }
        harness.sidebarStore.save(.fixed(.artists))
        try await harness.seed(source: .playlist(id: 73), track: harness.playableTrack)

        #expect(await harness.restorer.restore(profileId: ProfileRecord.guestID))
        let navigation = NavigationModel(store: harness.sidebarStore)

        #expect(navigation.sidebar == .playlist(id: 73))
        #expect(harness.coordinator.state.current == harness.playableTrack)
        #expect(harness.coordinator.state.playback != .playing)
        #expect(harness.restoredSource == .playlist(id: 73))
    }

    @Test("search source with missing file restores queue and leaves sidebar untouched")
    func searchMissingFileRestoresWithoutNavigationOrCrash() async throws {
        let harness = try LaunchRestoreHarness(missingFilesFailToLoad: true)
        defer { harness.cleanUp() }
        let existingSelection = SidebarDestination.fixed(.albums)
        harness.sidebarStore.save(existingSelection)
        try await harness.seed(source: .search, track: harness.missingTrack)

        #expect(await harness.restorer.restore(profileId: ProfileRecord.guestID))

        #expect(harness.sidebarStore.load() == existingSelection)
        #expect(harness.coordinator.state.current == harness.missingTrack)
        #expect(harness.coordinator.state.current?.isPlayable == false)
        #expect(harness.coordinator.state.playback != .playing)
        #expect(harness.restoredSource == .search)
    }

    @Test("a deleted current file restores unavailable and paused without a cached handle")
    func deletedCurrentFileRestoresUnavailableAndPaused() async throws {
        let harness = try LaunchRestoreHarness(missingFilesFailToLoad: true)
        defer { harness.cleanUp() }
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macamp-deleted-current-\(UUID().uuidString).missing")
        try Data("fixture".utf8).write(to: fileURL)
        try FileManager.default.removeItem(at: fileURL)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        let deletedTrack = TrackRef(
            filePath: fileURL.path,
            title: "Deleted",
            availability: .missing
        )
        try await harness.seed(source: .search, track: deletedTrack)

        #expect(await harness.restorer.restore(profileId: ProfileRecord.guestID))

        #expect(harness.coordinator.state.current == deletedTrack)
        #expect(harness.coordinator.state.current?.isPlayable == false)
        #expect(harness.coordinator.state.playback != .playing)
    }
}

@MainActor
private final class LaunchRestoreHarness {
    let database: AppDatabase
    let coordinator: PlaybackCoordinator
    let sidebarStore: SidebarSelectionStore
    let playableTrack = TrackRef(
        filePath: "/fixtures/playable.fake",
        title: "Playable",
        availability: .present
    )
    let missingTrack = TrackRef(
        filePath: "/fixtures/missing.missing",
        title: "Missing",
        availability: .missing
    )

    private let suiteName = "com.example.macamp.tests.launch-restore.\(UUID().uuidString)"
    private let stateRepository: ProfilePlaybackStateRepository
    private(set) var restoredSource: PlaybackSource?
    lazy var restorer = PlaybackStateRestorer(
        repository: stateRepository,
        rootRepository: LibraryRootRepository(database),
        coordinator: coordinator,
        sidebarStore: sidebarStore,
        sourceDidRestore: { [weak self] in self?.restoredSource = $0 }
    )

    init(missingFilesFailToLoad: Bool = false) throws {
        let database = try AppDatabase.makeEmpty()
        let decoder = FakeDecoderProvider(
            duration: 100,
            unsupportedExtensions: missingFilesFailToLoad ? ["missing"] : []
        )
        self.database = database
        coordinator = PlaybackCoordinator(engine: FakePlaybackEngine(decoderProvider: decoder))
        sidebarStore = SidebarSelectionStore(
            profileId: ProfileRecord.guestID,
            suiteName: suiteName,
            key: "sidebar-selection"
        )
        stateRepository = ProfilePlaybackStateRepository(database)
    }

    func seed(source: PlaybackSource, track: TrackRef) async throws {
        let snapshot = CoordinatorSnapshot(
            entries: [track],
            order: [track.id],
            currentID: track.id,
            shuffle: false,
            repeatMode: .off,
            position: 27.5
        )
        let snapshotData = try JSONEncoder().encode(snapshot)
        let sourceData = try JSONEncoder().encode(source)
        let snapshotJson = try #require(String(data: snapshotData, encoding: .utf8))
        let sourceJson = try #require(String(data: sourceData, encoding: .utf8))
        try await stateRepository.upsert(
            for: ProfileRecord.guestID,
            snapshotJson: snapshotJson,
            sourceJson: sourceJson,
            savedAt: 1
        )
    }

    func cleanUp() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
}
