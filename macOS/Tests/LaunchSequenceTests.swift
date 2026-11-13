// LaunchSequenceTests — the launch split: a scan-free fast phase, then an owned,
// background catch-up.
//
// The split is invisible to a screenshot, so each half is pinned here: `restore()`
// must touch no filesystem, and `beginCatchUp()` must schedule BOTH the DB-first
// projection publish and the catch-up refresh, exactly once.
//
// The offline lyrics sweep hangs off that same split — it must NOT start while the
// catch-up scan is still walking the roots, and must still re-arm on every content
// refresh after it, so both halves of that gate are pinned here too.
import Artwork
import AudioEngine
import DSP
import Foundation
import Lyrics
@testable import MacAMP
import Metadata
import Persistence
import Services
import Testing
import ViewModels

@MainActor
@Suite("LaunchSequenceTests", .serialized)
struct LaunchSequenceTests {
    @Test("the fast restore phase completes without scanning the library")
    func restoreRunsNoScan() async throws {
        let harness = try LaunchSequenceHarness()

        await harness.controller.restore()

        #expect(harness.scanner.scanCount == 0)
        #expect(harness.access.roots.count == 1)
    }

    @Test("catch-up publishes projections and scans, landing two operations")
    func catchUpPublishesProjectionsThenScans() async throws {
        let harness = try LaunchSequenceHarness()
        await harness.controller.restore()
        // Composition registers roots through an asynchronous callback, so an
        // operation can still be in flight here. Draining first makes the baseline
        // relative to a quiet coordinator instead of a racing one.
        await harness.folders.waitForIdle()
        let baseline = harness.folders.revision

        harness.controller.beginCatchUp()

        try await harness.waitForRevision(atLeast: baseline + 2)
        #expect(harness.folders.revision >= baseline + 2)
        #expect(harness.scanner.scanCount == 1)
    }

    @Test("a second catch-up is a no-op")
    func secondCatchUpDoesNothing() async throws {
        let harness = try LaunchSequenceHarness()
        await harness.controller.restore()
        await harness.folders.waitForIdle()
        let baseline = harness.folders.revision
        harness.controller.beginCatchUp()
        try await harness.waitForRevision(atLeast: baseline + 2)
        await harness.folders.waitForIdle()
        let settled = harness.folders.revision

        harness.controller.beginCatchUp()
        await harness.folders.waitForIdle()

        #expect(harness.scanner.scanCount == 1)
        #expect(harness.folders.revision == settled)
    }

    @Test("a refresh raised before the catch-up lands leaves the sweep to the catch-up")
    func lyricsSweepWaitsForTheCatchUp() async throws {
        let harness = try LaunchSequenceHarness(seededTracks: 3)
        defer { harness.cleanUp() }
        let sweep = try #require(harness.environment.lyricsSweep as? LyricsSweepService)
        await harness.controller.restore()

        // The catch-up publishes projections BEFORE its scan lands, and it was that
        // refresh — not the fast phase — that used to run the sweep alongside the
        // scan. Raising it on its own is what makes this an ordering assertion.
        harness.folders.publishProjections()
        await harness.folders.waitForIdle()
        await sweep.waitForCompletion()

        #expect(!harness.folders.launchCatchUpComplete)
        let duringCatchUp = try await harness.unprobedTrackCount()
        #expect(duringCatchUp == 3)

        harness.controller.beginCatchUp()
        try await harness.waitForCatchUpComplete()
        await sweep.waitForCompletion()

        #expect(harness.folders.launchCatchUpComplete)
        let afterCatchUp = try await harness.unprobedTrackCount()
        #expect(afterCatchUp == 0)
    }

    @Test("a content refresh after the catch-up still re-arms the sweep")
    func laterRefreshStillRearmsTheSweep() async throws {
        let harness = try LaunchSequenceHarness()
        defer { harness.cleanUp() }
        let sweep = try #require(harness.environment.lyricsSweep as? LyricsSweepService)
        await harness.controller.restore()
        harness.controller.beginCatchUp()
        try await harness.waitForCatchUpComplete()
        await sweep.waitForCompletion()

        try harness.seedTracks(count: 2)
        let pending = try await harness.unprobedTrackCount()
        #expect(pending == 2)

        harness.folders.publishProjections()
        await harness.folders.waitForIdle()
        await sweep.waitForCompletion()

        let swept = try await harness.unprobedTrackCount()
        #expect(swept == 0)
    }

    @Test("a profile switched mid-catch-up refreshes under the incoming profile")
    func profileSwitchedMidCatchUpUsesIncomingProfile() async throws {
        let harness = try FolderScopeHarness()

        await harness.coordinator.startWatchingAndScheduleCatchUp()
        // The scheduled operation cannot run until this test suspends, so this
        // assignment lands strictly before the refresh resolves the profile.
        harness.scope.activeProfileId = FolderScopeHarness.incomingProfileId
        await harness.coordinator.waitForIdle()

        #expect(!harness.scope.observed.isEmpty)
        #expect(harness.scope.observed.last == FolderScopeHarness.incomingProfileId)
    }
}

// MARK: - Full-environment harness

/// A complete `AppEnvironment` — so the real `StateRestorationController` path runs —
/// on an in-memory database with one configured root and a counting scanner.
@MainActor
private final class LaunchSequenceHarness {
    let scanner = CountingScanner()
    let access: LibraryAccessController
    let environment: AppEnvironment
    let controller: StateRestorationController
    let database: AppDatabase
    let fixtureDirectory: URL

    var folders: LibraryFolderCoordinator {
        environment.libraryFolders
    }

    init(seededTracks: Int = 0) throws {
        let database = try AppDatabase.makeEmpty()
        self.database = database
        fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchSequence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        try Self.seed(seededTracks, into: database, at: fixtureDirectory)
        let rootsStore = GRDBLibraryRootsStore(
            repository: LibraryRootRepository(database),
            profileId: ProfileRecord.guestID
        )
        rootsStore.save([URL(fileURLWithPath: "/Music/LaunchSequence")])
        let scanner = scanner
        let access = LibraryAccessController(
            store: rootsStore,
            picker: FakeFolderPicker(),
            probe: FakeFileAccessProbe(),
            settings: FakeSystemSettingsOpener()
        )
        self.access = access
        environment = AppEnvironment(
            AppEnvironment.Dependencies(
                database: database,
                engine: FakePlaybackEngine(),
                artworkProvider: FakeArtworkProvider(),
                metadataFetcher: MockMetadataFetcher(),
                infoService: InfoService(fetcher: MockInfoFetcher(), database: database),
                lyricsProvider: FakeLyricsProvider(),
                presetStore: FakeEQPresetStore(),
                spectrumSource: SpectrumProvider(),
                scanner: scanner,
                watchService: LibraryWatchService(
                    scanner: scanner,
                    reconciler: AvailabilityReconciler(database),
                    store: rootsStore
                ),
                libraryAccess: access,
                snapshotWriter: nil,
                profileService: ProfileService(
                    profileRepository: ProfileRepository(database),
                    defaults: UserDefaults(suiteName: Self.defaultsSuite) ?? .standard
                ),
                rootsStore: rootsStore,
                karaoke: .inert
            )
        )
        controller = StateRestorationController(environment: environment, settings: AppSettings())
    }

    /// Polls until the coordinator has published `target` operations, or gives up.
    /// The catch-up is deliberately detached, so there is no task to await instead.
    func waitForRevision(atLeast target: Int) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while folders.revision < target, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Polls for the catch-up's latch. The sweep is started in the same synchronous
    /// step that sets it, so observing it `true` also means the pass has been started.
    func waitForCatchUpComplete() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !folders.launchCatchUpComplete, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// How many present tracks the sweep still has to probe — its own anti-join, so
    /// "the sweep ran" is read off the rows it leaves behind rather than a spy.
    func unprobedTrackCount() async throws -> Int {
        try await TrackRepository(database).filePathsWithoutLyricsProbe(after: nil, limit: 500).count
    }

    func seedTracks(count: Int) throws {
        try Self.seed(count, into: database, at: fixtureDirectory)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: fixtureDirectory)
    }

    /// Inserts `count` present tracks backed by REAL (empty) files: the catch-up
    /// reconciles availability against the live file system, so a row pointing at a
    /// path that does not exist flips to `missing` and the sweep skips it — making
    /// any "the sweep probed them" assertion pass vacuously.
    private static func seed(_ count: Int, into database: AppDatabase, at directory: URL) throws {
        guard count > 0 else { return }
        let repository = TrackRepository(database)
        for _ in 0 ..< count {
            let url = directory.appendingPathComponent("seed-\(UUID().uuidString).flac")
            FileManager.default.createFile(atPath: url.path, contents: Data())
            _ = try repository.insert(TrackRecord(filePath: url.path))
        }
    }

    private static let defaultsSuite = "com.example.macamp.tests.launch-sequence"
}

// MARK: - Profile-scope harness

/// A bare coordinator whose profile seam is settable and recorded, so a switch
/// landing after the refresh was scheduled can be observed directly.
@MainActor
private final class FolderScopeHarness {
    static let incomingProfileId: Int64 = 77

    let scope = ProfileScopeRecorder()
    let coordinator: LibraryFolderCoordinator

    init() throws {
        let database = try AppDatabase.makeEmpty()
        let rootsStore = GRDBLibraryRootsStore(
            repository: LibraryRootRepository(database),
            profileId: ProfileRecord.guestID
        )
        rootsStore.save([URL(fileURLWithPath: "/Music/ProfileScope")])
        let scanner = CountingScanner()
        let recorder = scope
        coordinator = LibraryFolderCoordinator(
            access: LibraryAccessController(
                store: rootsStore,
                picker: FakeFolderPicker(),
                probe: FakeFileAccessProbe(),
                settings: FakeSystemSettingsOpener()
            ),
            scanner: scanner,
            watchService: LibraryWatchService(
                scanner: scanner,
                reconciler: AvailabilityReconciler(database),
                store: rootsStore
            ),
            sidebar: FolderSidebarViewModel(repository: TrackRepository(database)),
            toast: ToastManager(),
            activeProfileId: { recorder.resolve() }
        )
        coordinator.connect {}
    }
}

/// Owns both the live profile id and the log of what the coordinator resolved, so
/// the escaping seam can be installed during construction without a cycle.
@MainActor
private final class ProfileScopeRecorder {
    var activeProfileId = ProfileRecord.guestID
    private(set) var observed: [Int64] = []

    func resolve() -> Int64 {
        observed.append(activeProfileId)
        return activeProfileId
    }
}

// MARK: - Counting scanner

/// Counts directory scans without touching the filesystem, so "the fast phase is
/// scan-free" is an assertion rather than a hope.
private final class CountingScanner: LibraryScanning, @unchecked Sendable {
    private let lock = NSLock()
    private var scans = 0

    var scanCount: Int {
        lock.withLock { scans }
    }

    func events(for request: ScanRequest) -> AsyncStream<ScanEvent> {
        record(request)
        return AsyncStream { continuation in
            continuation.yield(.finished(ScanSummary()))
            continuation.finish()
        }
    }

    func scan(_ request: ScanRequest) async -> ScanSummary {
        record(request)
        return ScanSummary()
    }

    private func record(_ request: ScanRequest) {
        guard case .directory = request else { return }
        lock.withLock { scans += 1 }
    }
}
