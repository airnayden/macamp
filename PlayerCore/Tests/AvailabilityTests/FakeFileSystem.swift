import Foundation
@testable import Persistence

/// A deterministic, in-memory ``FileSystemProbing`` for availability tests.
///
/// Models files and volumes without touching the real file system. A file is
/// only *reachable* when it is both present **and** on a mounted volume, so
/// unmounting a volume makes its files disappear exactly as a real unplug would
/// — while the file stays "on the drive" and reappears on remount.
final class FakeFileSystem: FileSystemProbing, @unchecked Sendable {
    private struct FakeVolume: Equatable {
        var root: URL
        var isExternal: Bool
        var isMounted: Bool
    }

    private let lock = NSLock()
    private var files: Set<String>
    private var volumes: [FakeVolume]
    private var fileExistsLog: [String] = []
    private var volumeLog: [String] = []

    init(files: Set<String> = []) {
        self.files = files
        volumes = []
    }

    // MARK: - Probe accounting

    /// Paths passed to ``fileExists(atPath:)``, in call order.
    var fileExistsCalls: [String] {
        lock.withLock { fileExistsLog }
    }

    /// Paths passed to ``volume(forPath:)``, in call order. Internal
    /// longest-prefix lookups made by ``fileExists(atPath:)`` are not recorded —
    /// only the seam the reconciler itself calls.
    var volumeCalls: [String] {
        lock.withLock { volumeLog }
    }

    func resetProbeLog() {
        lock.withLock {
            fileExistsLog = []
            volumeLog = []
        }
    }

    // MARK: - Test control

    /// Defines (or redefines) a known volume by its mount root.
    func defineVolume(root: URL, isExternal: Bool, isMounted: Bool) {
        let standardized = root.standardizedFileURL
        lock.withLock {
            volumes.removeAll { $0.root == standardized }
            volumes.append(FakeVolume(root: standardized, isExternal: isExternal, isMounted: isMounted))
        }
    }

    /// Marks a previously defined volume mounted or unmounted.
    func setVolumeMounted(_ mounted: Bool, root: URL) {
        let standardized = root.standardizedFileURL
        lock.withLock {
            guard let index = volumes.firstIndex(where: { $0.root == standardized }) else { return }
            volumes[index].isMounted = mounted
        }
    }

    func addFile(_ path: String) {
        lock.withLock { _ = files.insert(path) }
    }

    func removeFile(_ path: String) {
        lock.withLock { _ = files.remove(path) }
    }

    // MARK: - FileSystemProbing

    func fileExists(atPath path: String) -> Bool {
        lock.withLock {
            fileExistsLog.append(path)
            guard files.contains(path) else { return false }
            // A file on an unmounted volume is inaccessible.
            return volumeLocked(forPath: path).isMounted
        }
    }

    func mountedVolumeURLs() -> [URL] {
        lock.withLock { volumes.filter(\.isMounted).map(\.root) }
    }

    func volume(forPath path: String) -> VolumeIdentity {
        lock.withLock {
            volumeLog.append(path)
            return volumeLocked(forPath: path)
        }
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
