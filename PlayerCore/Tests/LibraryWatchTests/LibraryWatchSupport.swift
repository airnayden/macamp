// Test doubles for the folder-loading wiring suite.
//
// LibraryWatchService / LibraryReconciliationCoordinator are macOS-app-target
// types (they own an FSEvents FolderWatcher), so they cannot be linked here.
// These doubles model the Persistence-level contract the wiring drives: a folder
// scan imports the folder's tracks, and an availability reconcile re-derives each
// track's state. Persistence-only (no Services / Metadata / audio stack) so the
// contract is exercised in isolation.
import Foundation
import Persistence

/// Stands in for the real ``LibraryScanner``'s observable effect: scanning a
/// directory imports one ``TrackRecord`` per discovered file into the (real,
/// in-memory) library, and the call is counted so a test can assert that adding a
/// root triggers exactly one scan. Inserts dedupe on `filePath` (the real
/// scanner's fingerprint skip), so re-scanning a root never duplicates rows.
final class InsertingScanner: @unchecked Sendable {
    private let database: AppDatabase
    private let files: [String]
    private let lock = NSLock()
    private var scanCalls = 0

    init(database: AppDatabase, files: [String]) {
        self.database = database
        self.files = files
    }

    /// How many times ``scan(directory:)`` has run.
    var scanCount: Int {
        lock.withLock { scanCalls }
    }

    @discardableResult
    func scan(directory _: URL) async -> Int {
        lock.withLock { scanCalls += 1 }
        let repository = TrackRepository(database)
        var added = 0
        for path in files {
            let existing = try? repository.fetchTrack(filePath: path)
            guard (existing ?? nil) == nil else { continue }
            let record = TrackRecord(
                filePath: path,
                title: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                availability: .present
            )
            if (try? repository.insert(record)) != nil {
                added += 1
            }
        }
        return added
    }
}

/// A deterministic, in-memory ``FileSystemProbing`` for the remove-root tests.
///
/// A file is reachable only when present **and** on a mounted volume — so
/// clearing the file set (a removed root whose files are gone) reads as
/// ``Availability/missing``, and unmounting an external volume reads as
/// ``Availability/externalOffline``.
final class FakeFileSystem: FileSystemProbing, @unchecked Sendable {
    private struct FakeVolume: Equatable {
        var root: URL
        var isExternal: Bool
        var isMounted: Bool
    }

    private let lock = NSLock()
    private var files: Set<String>
    private var volumes: [FakeVolume]

    init(files: Set<String> = []) {
        self.files = files
        volumes = []
    }

    func addFile(_ path: String) {
        lock.withLock { _ = files.insert(path) }
    }

    func removeFile(_ path: String) {
        lock.withLock { _ = files.remove(path) }
    }

    func defineVolume(root: URL, isExternal: Bool, isMounted: Bool) {
        let standardized = root.standardizedFileURL
        lock.withLock {
            volumes.removeAll { $0.root == standardized }
            volumes.append(FakeVolume(root: standardized, isExternal: isExternal, isMounted: isMounted))
        }
    }

    func setVolumeMounted(_ mounted: Bool, root: URL) {
        let standardized = root.standardizedFileURL
        lock.withLock {
            guard let index = volumes.firstIndex(where: { $0.root == standardized }) else { return }
            volumes[index].isMounted = mounted
        }
    }

    // MARK: - FileSystemProbing

    func fileExists(atPath path: String) -> Bool {
        lock.withLock {
            guard files.contains(path) else { return false }
            return volumeLocked(forPath: path).isMounted
        }
    }

    func mountedVolumeURLs() -> [URL] {
        lock.withLock { volumes.filter(\.isMounted).map(\.root) }
    }

    func volume(forPath path: String) -> VolumeIdentity {
        lock.withLock { volumeLocked(forPath: path) }
    }

    /// Longest-prefix match against the known volumes. Caller must hold `lock`.
    private func volumeLocked(forPath path: String) -> VolumeIdentity {
        let pathComponents = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        var best: FakeVolume?
        var bestCount = -1
        for volume in volumes {
            let rootComponents = volume.root.pathComponents
            guard rootComponents.count <= pathComponents.count else { continue }
            guard Array(pathComponents.prefix(rootComponents.count)) == rootComponents else { continue }
            if rootComponents.count > bestCount {
                best = volume
                bestCount = rootComponents.count
            }
        }
        if let volume = best {
            return VolumeIdentity(root: volume.root, isExternal: volume.isExternal, isMounted: volume.isMounted)
        }
        return VolumeIdentity(
            root: URL(fileURLWithPath: "/").standardizedFileURL,
            isExternal: false,
            isMounted: true
        )
    }
}
