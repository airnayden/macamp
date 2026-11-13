import Foundation
import GRDB
@testable import Persistence
import Testing

/// Behavioural tests for the track-availability state machine.
///
/// Every test uses an isolated in-memory database (``AppDatabase/makeEmpty()``)
/// and a deterministic ``FakeFileSystem`` so nothing touches real files or real
/// volumes. The load-bearing invariant under test: reconciliation **never**
/// deletes a row — it only rewrites the `availability` column.
struct AvailabilityReconcilerTests {
    // MARK: - Helpers

    private func makeTrack(_ filePath: String) -> TrackRecord {
        TrackRecord(filePath: filePath, title: "Song", availability: .present)
    }

    private func trackCount(_ database: AppDatabase) throws -> Int {
        try database.writer.read { db in try TrackRecord.fetchCount(db) }
    }

    private func availability(of id: Int64, in repository: TrackRepository) throws -> Availability {
        let row = try repository.fetchTrack(id: id)
        let track = try #require(row)
        return track.availability
    }

    // MARK: - missing / restore (internal volume)

    @Test func missingFileFlipsToMissingAndRetainsRow() throws {
        let database = try AppDatabase.makeEmpty()
        let repository = TrackRepository(database)
        let fileSystem = FakeFileSystem()
        let path = "/Music/Library/song.mp3"
        fileSystem.addFile(path)
        let inserted = try repository.insert(makeTrack(path))
        let id = try #require(inserted.id)
        let reconciler = AvailabilityReconciler(database, fileSystem: fileSystem)

        _ = try reconciler.reconcile()
        try #expect(availability(of: id, in: repository) == .present)

        // The file disappears from a local (internal) volume.
        fileSystem.removeFile(path)
        let summary = try reconciler.reconcile()

        try #expect(availability(of: id, in: repository) == .missing)
        #expect(summary.markedMissing == 1)
        // Row retained — the track is still in the library, just unavailable.
        let stillPresent = try repository.fetchTrack(id: id)
        #expect(stillPresent != nil)
        try #expect(trackCount(database) == 1)
    }

    @Test func restoringFileFlipsBackToPresent() throws {
        let database = try AppDatabase.makeEmpty()
        let repository = TrackRepository(database)
        let fileSystem = FakeFileSystem()
        let path = "/Music/Library/restore.mp3"
        fileSystem.addFile(path)
        let inserted = try repository.insert(makeTrack(path))
        let id = try #require(inserted.id)
        let reconciler = AvailabilityReconciler(database, fileSystem: fileSystem)

        fileSystem.removeFile(path)
        _ = try reconciler.reconcile()
        try #expect(availability(of: id, in: repository) == .missing)

        // The file reappears at the same path.
        fileSystem.addFile(path)
        let summary = try reconciler.reconcile()

        try #expect(availability(of: id, in: repository) == .present)
        #expect(summary.markedPresent == 1)
    }

    // MARK: - external offline / remount

    @Test func unmountedExternalVolumeFlipsToExternalOffline() throws {
        let database = try AppDatabase.makeEmpty()
        let repository = TrackRepository(database)
        let fileSystem = FakeFileSystem()
        let volumeRoot = URL(fileURLWithPath: "/Volumes/Backup")
        fileSystem.defineVolume(root: volumeRoot, isExternal: true, isMounted: true)
        let path = "/Volumes/Backup/Music/external.mp3"
        fileSystem.addFile(path)
        let inserted = try repository.insert(makeTrack(path))
        let id = try #require(inserted.id)
        let reconciler = AvailabilityReconciler(database, fileSystem: fileSystem)

        _ = try reconciler.reconcile()
        try #expect(availability(of: id, in: repository) == .present)

        // The external drive is ejected.
        fileSystem.setVolumeMounted(false, root: volumeRoot)
        let summary = try reconciler.reconcile()

        // Offline, NOT permanently missing — and the row is retained.
        try #expect(availability(of: id, in: repository) == .externalOffline)
        try #expect(availability(of: id, in: repository) != .missing)
        #expect(summary.markedExternalOffline == 1)
        try #expect(trackCount(database) == 1)
    }

    @Test func remountingExternalVolumeFlipsBackToPresent() throws {
        let database = try AppDatabase.makeEmpty()
        let repository = TrackRepository(database)
        let fileSystem = FakeFileSystem()
        let volumeRoot = URL(fileURLWithPath: "/Volumes/Backup")
        fileSystem.defineVolume(root: volumeRoot, isExternal: true, isMounted: true)
        let path = "/Volumes/Backup/Music/external.mp3"
        fileSystem.addFile(path)
        let inserted = try repository.insert(makeTrack(path))
        let id = try #require(inserted.id)
        let reconciler = AvailabilityReconciler(database, fileSystem: fileSystem)

        fileSystem.setVolumeMounted(false, root: volumeRoot)
        _ = try reconciler.reconcile()
        try #expect(availability(of: id, in: repository) == .externalOffline)

        // The drive is plugged back in.
        fileSystem.setVolumeMounted(true, root: volumeRoot)
        let summary = try reconciler.reconcile()

        try #expect(availability(of: id, in: repository) == .present)
        #expect(summary.markedPresent == 1)
    }

    @Test func mountedExternalVolumeWithDeletedFileFlipsToMissing() throws {
        let database = try AppDatabase.makeEmpty()
        let repository = TrackRepository(database)
        let fileSystem = FakeFileSystem()
        let volumeRoot = URL(fileURLWithPath: "/Volumes/Backup")
        fileSystem.defineVolume(root: volumeRoot, isExternal: true, isMounted: true)
        let path = "/Volumes/Backup/Music/deleted.mp3"
        fileSystem.addFile(path)
        let inserted = try repository.insert(makeTrack(path))
        let id = try #require(inserted.id)
        let reconciler = AvailabilityReconciler(database, fileSystem: fileSystem)

        // The drive stays mounted but the file is genuinely deleted.
        fileSystem.removeFile(path)
        _ = try reconciler.reconcile()

        // Mounted external volume + gone file = missing, not externalOffline.
        try #expect(availability(of: id, in: repository) == .missing)
    }

    // MARK: - no-delete invariant

    @Test func reconciliationNeverDeletesRows() throws {
        let database = try AppDatabase.makeEmpty()
        let repository = TrackRepository(database)
        let fileSystem = FakeFileSystem()
        let volumeRoot = URL(fileURLWithPath: "/Volumes/Backup")
        fileSystem.defineVolume(root: volumeRoot, isExternal: true, isMounted: true)

        let localPath = "/Music/Library/local.mp3"
        let externalPath = "/Volumes/Backup/Music/external.mp3"
        fileSystem.addFile(localPath)
        fileSystem.addFile(externalPath)
        try repository.insert(makeTrack(localPath))
        try repository.insert(makeTrack(externalPath))
        let reconciler = AvailabilityReconciler(database, fileSystem: fileSystem)

        // Everything present.
        _ = try reconciler.reconcile()
        try #expect(trackCount(database) == 2)

        // Local file deleted, external drive ejected.
        fileSystem.removeFile(localPath)
        fileSystem.setVolumeMounted(false, root: volumeRoot)
        _ = try reconciler.reconcile()
        try #expect(trackCount(database) == 2)

        // Everything restored.
        fileSystem.addFile(localPath)
        fileSystem.setVolumeMounted(true, root: volumeRoot)
        _ = try reconciler.reconcile()
        try #expect(trackCount(database) == 2)
    }

    // MARK: - probe economics

    @Test func probesEachRowOnceAndAsksForAVolumeOnlyWhenTheFileIsGone() throws {
        let database = try AppDatabase.makeEmpty()
        let repository = TrackRepository(database)
        let fileSystem = FakeFileSystem()
        let present = "/Music/Library/present.mp3"
        let gone = "/Music/Library/gone.mp3"
        fileSystem.addFile(present)
        try repository.insert(makeTrack(present))
        try repository.insert(makeTrack(gone))
        let reconciler = AvailabilityReconciler(database, fileSystem: fileSystem)

        fileSystem.resetProbeLog()
        let summary = try reconciler.reconcile()

        #expect(summary.scanned == 2)
        // One existence probe per row: the snapshot is walked exactly once.
        #expect(fileSystem.fileExistsCalls.sorted() == [gone, present].sorted())
        // The short-circuit survives the phase split — a reachable file never
        // asks about its volume.
        #expect(fileSystem.volumeCalls == [gone])
    }

    @Test func volumeIdentityIsResolvedOncePerDistinctVolume() throws {
        let database = try AppDatabase.makeEmpty()
        let repository = TrackRepository(database)
        let fileSystem = FakeFileSystem()
        let volumeRoot = URL(fileURLWithPath: "/Volumes/Backup")
        fileSystem.defineVolume(root: volumeRoot, isExternal: true, isMounted: true)
        for index in 1 ... 3 {
            let path = "/Volumes/Backup/Music/track\(index).mp3"
            fileSystem.addFile(path)
            try repository.insert(makeTrack(path))
        }
        let reconciler = AvailabilityReconciler(database, fileSystem: fileSystem)
        _ = try reconciler.reconcile()

        // The drive is ejected: three files miss, all on one volume.
        fileSystem.setVolumeMounted(false, root: volumeRoot)
        fileSystem.resetProbeLog()
        let summary = try reconciler.reconcile()

        #expect(summary.markedExternalOffline == 3)
        #expect(fileSystem.fileExistsCalls.count == 3)
        // Memoised per mount root: three misses on one drive ask once.
        #expect(fileSystem.volumeCalls.count == 1)
    }

    // MARK: - probes hold no write lock

    /// Proves phase 2 runs with **no** write transaction open.
    ///
    /// A file-backed `DatabasePool` is required: a second, independent connection
    /// to the same file is what makes SQLite's write lock observable. Every probe
    /// attempts `pool2.write`, whose `BEGIN IMMEDIATE` takes the write lock before
    /// any statement inside it runs; under the default `.immediateError` busy mode
    /// that either succeeds at once or throws `SQLITE_BUSY` at once, never blocks.
    /// Zero busy errors across a whole pass means no probe ever overlapped an open
    /// write transaction. The negative control at the end fails the same probe from
    /// inside a real write transaction, so a zero count is evidence rather than a
    /// dead detector.
    @Test func fileSystemProbesNeverOverlapAnOpenWriteTransaction() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("availability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var configuration = Configuration()
        configuration.journalMode = .wal
        let dbPath = directory.appendingPathComponent("library.sqlite").path
        let database = try AppDatabase(DatabasePool(path: dbPath, configuration: configuration))
        let repository = TrackRepository(database)
        let rival = try DatabasePool(path: dbPath, configuration: configuration)

        let fileSystem = FakeFileSystem()
        let present = "/Music/Library/kept.mp3"
        fileSystem.addFile(present)
        try repository.insert(makeTrack(present))
        try repository.insert(makeTrack("/Music/Library/vanished.mp3"))

        let observed = BusyObservation()
        let probed = WriteLockObservingFileSystem(fileSystem) {
            observed.record(writeLockIsHeld(rival))
        }
        let summary = try AvailabilityReconciler(database, fileSystem: probed).reconcile()

        // The pass did real work — one row flipped, so phase 3 opened a genuine
        // write transaction that the probes could have collided with.
        #expect(summary.markedMissing == 1)
        #expect(observed.probeCount > 0)
        #expect(observed.busyCount == 0)

        // Negative control: the same probe DOES see the lock when one is held.
        var control = false
        try database.writer.write { _ in control = writeLockIsHeld(rival) }
        #expect(control)
    }
}

// MARK: - Write-lock observation helpers

/// Attempts an immediate write on an independent connection to the same file.
/// - Returns: `true` when SQLite reports the write lock already taken.
private func writeLockIsHeld(_ pool: DatabasePool) -> Bool {
    do {
        try pool.write { db in try db.execute(sql: "SELECT 1") }
        return false
    } catch let error as DatabaseError {
        return error.resultCode == .SQLITE_BUSY
    } catch {
        return false
    }
}

/// Tallies write-lock observations across a reconciliation pass.
private final class BusyObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var probes = 0
    private var busy = 0

    var probeCount: Int {
        lock.withLock { probes }
    }

    var busyCount: Int {
        lock.withLock { busy }
    }

    func record(_ wasBusy: Bool) {
        lock.withLock {
            probes += 1
            if wasBusy { busy += 1 }
        }
    }
}

/// A ``FileSystemProbing`` that runs `onProbe` before delegating each probe.
private final class WriteLockObservingFileSystem: FileSystemProbing, @unchecked Sendable {
    private let base: any FileSystemProbing
    private let onProbe: @Sendable () -> Void

    init(_ base: any FileSystemProbing, onProbe: @escaping @Sendable () -> Void) {
        self.base = base
        self.onProbe = onProbe
    }

    func fileExists(atPath path: String) -> Bool {
        onProbe()
        return base.fileExists(atPath: path)
    }

    func mountedVolumeURLs() -> [URL] {
        onProbe()
        return base.mountedVolumeURLs()
    }

    func volume(forPath path: String) -> VolumeIdentity {
        onProbe()
        return base.volume(forPath: path)
    }
}
