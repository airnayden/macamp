// Folder-loading wiring tests.
//
// These lock the scan-on-add and reconcile-on-remove contract that the three
// fixed import links drive end to end:
//
//   * Link A — PreferencesView builds `LibraryAccessController` with a real
//     `onRootsChanged` that calls `LibraryWatchService.updateRoots(_:)`.
//   * Link B — `AppEnvironment.live()` constructs & retains the one
//     `LibraryWatchService` (scanner + `AvailabilityReconciler` + roots store).
//   * Link C — at launch `StateRestoration` calls `watchService.start()` then
//     `reconcileAll()`.
//
// `LibraryWatchService` lives in the macOS app target (it owns an FSEvents
// `FolderWatcher`), which cannot be linked here, so these tests model the
// Persistence contract the wiring drives — a folder scan imports its tracks, and
// removing a root reconciles availability — proving the load-bearing behavior: a
// scan imports the folder's tracks, and removing a root marks its tracks
// unavailable WITHOUT ever deleting a library row.
import Foundation
import GRDB
import Persistence
import Testing

@Suite(.serialized)
struct LibraryWatchWiringTests {
    // MARK: - Helpers

    /// The three audio files a freshly-added root "contains".
    private static let rootPath = "/Music/Library"
    private static let flacFiles = [
        "\(rootPath)/01-first.flac",
        "\(rootPath)/02-second.flac",
        "\(rootPath)/03-third.flac",
    ]

    private func trackCount(_ database: AppDatabase) throws -> Int {
        try database.writer.read { db in try TrackRecord.fetchCount(db) }
    }

    private func allTracks(_ database: AppDatabase) throws -> [TrackRecord] {
        try database.writer.read { db in try TrackRecord.fetchAll(db) }
    }

    // MARK: - Link A/B: add a root -> scan imports its files

    /// Adding a root drives exactly one scan of that directory, and the scan
    /// imports the three `.flac` files as rows in the (real, in-memory) library.
    @Test func addingRootScansAndInsertsThreeRows() async throws {
        let database = try AppDatabase.makeEmpty()
        let scanner = InsertingScanner(database: database, files: Self.flacFiles)

        let root = URL(fileURLWithPath: Self.rootPath)
        _ = await scanner.scan(directory: root)

        #expect(scanner.scanCount == 1)
        try #expect(trackCount(database) == 3)
        let imported = try allTracks(database)
        #expect(imported.allSatisfy { $0.availability == .present })
        #expect(Set(imported.map(\.filePath)) == Set(Self.flacFiles))
    }

    // MARK: - Link B/C: remove a root -> reconcile marks missing, never deletes

    /// Removing a root (its files now gone from a local volume) and reconciling
    /// marks every one of its tracks ``Availability/missing`` while KEEPING the
    /// rows — the user, never the scanner, decides when to delete a track.
    @Test func removingRootMarksTracksMissingWithoutDeleting() async throws {
        let database = try AppDatabase.makeEmpty()
        let fileSystem = FakeFileSystem()
        for path in Self.flacFiles {
            fileSystem.addFile(path)
        }
        let scanner = InsertingScanner(database: database, files: Self.flacFiles)
        _ = await scanner.scan(directory: URL(fileURLWithPath: Self.rootPath))

        let reconciler = AvailabilityReconciler(database, fileSystem: fileSystem)
        _ = try reconciler.reconcile() // all present
        try #expect(trackCount(database) == 3)
        #expect(try allTracks(database).allSatisfy { $0.availability == .present })

        // The user removes the root and its files vanish from disk.
        for path in Self.flacFiles {
            fileSystem.removeFile(path)
        }
        let summary = try reconciler.reconcile()

        // No row was deleted — every track is retained, just marked missing.
        try #expect(trackCount(database) == 3)
        #expect(summary.markedMissing == 3)
        let tracks = try allTracks(database)
        #expect(tracks.count == 3)
        #expect(tracks.allSatisfy { $0.availability == .missing })
        #expect(tracks.allSatisfy { $0.availability != .present })
    }

    /// Removing a root that lived on an EXTERNAL volume (now unmounted) marks its
    /// tracks ``Availability/externalOffline`` — distinct from missing — and again
    /// never deletes a row.
    @Test func removingExternalRootMarksTracksExternalOffline() async throws {
        let database = try AppDatabase.makeEmpty()
        let fileSystem = FakeFileSystem()
        let volumeRoot = URL(fileURLWithPath: "/Volumes/Archive")
        fileSystem.defineVolume(root: volumeRoot, isExternal: true, isMounted: true)
        let externalFiles = [
            "/Volumes/Archive/FLAC/a.flac",
            "/Volumes/Archive/FLAC/b.flac",
            "/Volumes/Archive/FLAC/c.flac",
        ]
        for path in externalFiles {
            fileSystem.addFile(path)
        }
        let scanner = InsertingScanner(database: database, files: externalFiles)
        _ = await scanner.scan(directory: URL(fileURLWithPath: "/Volumes/Archive/FLAC"))

        let reconciler = AvailabilityReconciler(database, fileSystem: fileSystem)
        _ = try reconciler.reconcile()
        try #expect(trackCount(database) == 3)

        // The external drive is ejected (root removed while offline).
        fileSystem.setVolumeMounted(false, root: volumeRoot)
        let summary = try reconciler.reconcile()

        try #expect(trackCount(database) == 3)
        #expect(summary.markedExternalOffline == 3)
        let tracks = try allTracks(database)
        #expect(tracks.count == 3)
        #expect(tracks.allSatisfy { $0.availability == .externalOffline })
    }
}
