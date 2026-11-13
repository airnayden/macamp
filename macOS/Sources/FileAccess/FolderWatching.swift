// FolderWatching — the protocol seam over the FSEvents folder watcher, plus a
// deterministic fake.
//
// Mirrors the project's DI convention (every service is a protocol with a shipped
// `Fake`). Consumers depend on the abstraction so the reconciliation wiring can be
// tested without a real FSEvents stream or any filesystem activity: the fake lets
// a test drive the debounced "these roots changed" callback directly.
//
// The change callback is supplied at construction (not part of the protocol) so a
// watcher is a self-contained unit you start, retarget, and stop.
import Foundation

// MARK: - FolderWatching

/// Watches a set of library root folders for filesystem changes and invokes a
/// debounced, coalesced callback with the roots that need reconciling.
public protocol FolderWatching: AnyObject, Sendable {
    /// Begins watching `roots`, replacing any current watch set.
    func startWatching(_ roots: [URL])
    /// Retargets the watch set in place (add/remove a root) without a full stop.
    func updateRoots(_ roots: [URL])
    /// Stops watching and releases the underlying event stream.
    func stopWatching()
}

// MARK: - FakeFolderWatcher

/// A hermetic ``FolderWatching`` double: records start/stop/retarget calls and
/// lets a test fire the debounced callback via ``simulateChange(roots:)`` without
/// touching FSEvents or the filesystem.
public final class FakeFolderWatcher: FolderWatching, @unchecked Sendable {
    private let lock = NSLock()
    private let onRootsChanged: @Sendable (Set<String>) -> Void
    private var storedRoots: [URL] = []
    private var starts = 0
    private var stops = 0

    public init(onRootsChanged: @escaping @Sendable (Set<String>) -> Void = { _ in }) {
        self.onRootsChanged = onRootsChanged
    }

    public func startWatching(_ roots: [URL]) {
        lock.withLock {
            storedRoots = roots
            starts += 1
        }
    }

    public func updateRoots(_ roots: [URL]) {
        lock.withLock { storedRoots = roots }
    }

    public func stopWatching() {
        lock.withLock {
            storedRoots = []
            stops += 1
        }
    }

    /// The roots currently being watched (for test assertions).
    public var watchedRoots: [URL] {
        lock.withLock { storedRoots }
    }

    /// How many times ``startWatching(_:)`` has been called.
    public var startCount: Int {
        lock.withLock { starts }
    }

    /// How many times ``stopWatching()`` has been called.
    public var stopCount: Int {
        lock.withLock { stops }
    }

    /// Drives the debounced change callback directly, as if FSEvents had fired and
    /// the coalescer had flushed `roots`.
    public func simulateChange(roots: Set<String>) {
        onRootsChanged(roots)
    }
}
