import Foundation
import GRDB
@testable import MacAMP
import Persistence
import Services
import Testing
import ViewModels

@MainActor
@Suite("LibraryFolderCoordinatorTests", .serialized)
struct LibraryFolderCoordinatorTests {
    @Test("adding a root scans once and refreshes the sidebar and library projection")
    func addingRootScansAndRefreshesLiveState() async throws {
        let harness = try LibraryFolderHarness()
        let root = URL(fileURLWithPath: "/Music/New/../New")

        harness.access.addRoot(root)
        await harness.coordinator.waitForIdle()

        #expect(harness.scanner.directoryPaths == ["/Music/New"])
        #expect(harness.coordinator.sidebar.nodes.map(\.path) == ["/Music/New"])
        #expect(harness.contentRefreshCount == 1)
        #expect(harness.coordinator.revision == 1)
        #expect(harness.toast.activeToast?.text == String(localized: FileAccessStrings.folderAdded("New")))
    }

    @Test("refresh re-probes access, rescans every root, and publishes feedback")
    func refreshRescansAllRoots() async throws {
        let root = URL(fileURLWithPath: "/Music/Refresh")
        let harness = try LibraryFolderHarness(initialRoots: [root])
        let probesBeforeRefresh = harness.probe.callCount

        harness.coordinator.refreshLibrary()
        await harness.coordinator.waitForIdle()

        #expect(harness.probe.callCount > probesBeforeRefresh)
        #expect(harness.scanner.directoryPaths == [root.standardizedFileURL.path])
        #expect(harness.contentRefreshCount == 1)
        #expect(harness.toast.activeToast?.text == String(localized: FileAccessStrings.libraryRefreshed))
    }

    @Test("sidebar path removal clears the folder and removes its tracks from the library")
    func standardizedRemovalRemovesTheFoldersTracks() async throws {
        let root = URL(fileURLWithPath: "/Music/Remove")
        let harness = try LibraryFolderHarness(initialRoots: [root])
        try harness.insertTrack(root: root, title: "Removed With Folder")
        harness.coordinator.refreshProfileScope()
        await harness.coordinator.waitForIdle()
        harness.resetProjectionCount()

        let removed = harness.access.removeRoot(matchingPath: "/Music/Other/../Remove")
        await harness.coordinator.waitForIdle()

        #expect(removed)
        #expect(harness.access.roots.isEmpty)
        // The folder is gone from every profile, so its tracks leave the library
        // instead of lingering in All Tracks as "missing" loose files.
        #expect(try harness.track(title: "Removed With Folder") == nil)
        #expect(harness.coordinator.sidebar.nodes.isEmpty)
        #expect(harness.coordinator.sidebar.visibleNodes.isEmpty)
        #expect(harness.contentRefreshCount == 1)
        #expect(harness.toast.activeToast?.text == String(localized: FileAccessStrings.folderRemoved("Remove")))
    }

    @Test("profile rescope reloads access roots and refreshes the shared sidebar model")
    func profileRescopeRefreshesFolderOwnership() async throws {
        let harness = try LibraryFolderHarness(initialRoots: [URL(fileURLWithPath: "/Music/Guest")])
        let profile = try ProfileRepository(harness.database).create(ProfileRecord(name: "Second"))
        let profileID = try #require(profile.id)
        _ = try LibraryRootRepository(harness.database).addRoot(profileId: profileID, path: "/Music/Second")
        try harness.insertTrack(root: URL(fileURLWithPath: "/Music/Second"), title: "Second Profile")

        harness.rootsStore.activeProfileId = profileID
        harness.access.reloadRoots()
        harness.coordinator.refreshProfileScope()
        await harness.coordinator.waitForIdle()

        #expect(harness.access.roots.map(\.url.standardizedFileURL.path) == ["/Music/Second"])
        #expect(harness.coordinator.sidebar.nodes.map(\.path) == ["/Music/Second"])
    }

    @Test("filesystem aliases share one canonical root for sidebar and track removal")
    func filesystemAliasesShareCanonicalRoot() async throws {
        let configuredRoot = URL(fileURLWithPath: "/var/tmp")
        let canonicalRoot = URL(fileURLWithPath: "/private/var/tmp")
        let harness = try LibraryFolderHarness(initialRoots: [configuredRoot])
        try harness.insertTrack(root: canonicalRoot, title: "Alias Track")

        harness.coordinator.refreshProfileScope()
        await harness.coordinator.waitForIdle()

        #expect(harness.access.roots.map(\.url.path) == [canonicalRoot.path])
        #expect(harness.rootsStore.load().map(\.path) == [canonicalRoot.path])
        #expect(harness.coordinator.sidebar.nodes.map(\.path) == [canonicalRoot.path])

        let removed = harness.access.removeRoot(matchingPath: configuredRoot.path)
        await harness.coordinator.waitForIdle()

        #expect(removed)
        // Removing the alias removes the tracks stored under the canonical path.
        #expect(try harness.track(title: "Alias Track") == nil)
    }
}

@MainActor
private final class LibraryFolderHarness {
    let database: AppDatabase
    let rootsStore: GRDBLibraryRootsStore
    let scanner: RecordingLibraryScanner
    let probe = RecordingAccessProbe()
    let access: LibraryAccessController
    let toast = ToastManager()
    let coordinator: LibraryFolderCoordinator
    private(set) var contentRefreshCount = 0

    init(initialRoots: [URL] = []) throws {
        let database = try AppDatabase.makeEmpty()
        let rootsStore = GRDBLibraryRootsStore(
            repository: LibraryRootRepository(database),
            profileId: ProfileRecord.guestID
        )
        rootsStore.save(initialRoots)
        let scanner = RecordingLibraryScanner(database: database)
        let access = LibraryAccessController(
            store: rootsStore,
            picker: FakeFolderPicker(),
            probe: probe,
            settings: FakeSystemSettingsOpener()
        )
        let watchService = LibraryWatchService(
            scanner: scanner,
            reconciler: AvailabilityReconciler(database),
            store: rootsStore
        )
        let sidebar = FolderSidebarViewModel(repository: TrackRepository(database))

        self.database = database
        self.rootsStore = rootsStore
        self.scanner = scanner
        self.access = access
        coordinator = LibraryFolderCoordinator(
            access: access,
            scanner: scanner,
            watchService: watchService,
            sidebar: sidebar,
            toast: toast
        )
        coordinator.connect { [weak self] in self?.contentRefreshCount += 1 }
    }

    func insertTrack(root: URL, title: String) throws {
        var record = TrackRecord(
            filePath: root.appendingPathComponent("\(title).mp3").standardizedFileURL.path,
            title: title,
            sortTitle: title.lowercased(),
            availability: .present
        )
        try database.writer.write { db in try record.insert(db) }
    }

    func track(title: String) throws -> TrackRecord? {
        try database.writer.read { db in
            try TrackRecord.filter(TrackRecord.Columns.title == title).fetchOne(db)
        }
    }

    func resetProjectionCount() {
        contentRefreshCount = 0
    }
}

private final class RecordingAccessProbe: FileAccessProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int {
        lock.withLock { calls }
    }

    func status(of _: URL) -> FolderAccessStatus {
        lock.withLock { calls += 1 }
        return .accessible
    }
}

private final class RecordingLibraryScanner: LibraryScanning, @unchecked Sendable {
    private let database: AppDatabase
    private let lock = NSLock()
    private var paths: [String] = []

    init(database: AppDatabase) {
        self.database = database
    }

    var directoryPaths: [String] {
        lock.withLock { paths }
    }

    func events(for _: ScanRequest) -> AsyncStream<ScanEvent> {
        AsyncStream { continuation in
            continuation.yield(.finished(ScanSummary()))
            continuation.finish()
        }
    }

    func scan(_ request: ScanRequest) async -> ScanSummary {
        guard case let .directory(root) = request else { return ScanSummary() }
        let path = root.standardizedFileURL.path
        lock.withLock { paths.append(path) }
        let title = root.lastPathComponent
        let filePath = root.appendingPathComponent("\(title).mp3").standardizedFileURL.path
        let inserted = await (try? database.writer.write { db in
            guard try TrackRecord.filter(TrackRecord.Columns.filePath == filePath).fetchOne(db) == nil else {
                return false
            }
            var record = TrackRecord(
                filePath: filePath,
                title: title,
                sortTitle: title.lowercased(),
                availability: .present
            )
            try record.insert(db)
            return true
        }) ?? false
        return ScanSummary(added: inserted ? 1 : 0)
    }
}
