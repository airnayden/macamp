// FolderWatcher — the production ``FolderWatching`` backed by FSEvents.
//
// It NEVER polls the filesystem: it opens one `FSEventStreamRef` over the library
// roots and reacts to the kernel's change notifications. Every notification is
// funnelled through a ``PathEventCoalescer`` so a storm (e.g. renaming a parent of
// 50k files) collapses into a single debounced "re-scan these roots" callback
// instead of thousands of reconciliation passes.
//
// Concurrency contract: all mutable state (the stream, the coalescer, the watched
// roots, the debounce timer) is confined to one private serial `DispatchQueue`.
// The public entry points hop onto that queue, the FSEvents callback is delivered
// onto it (`FSEventStreamSetDispatchQueue`), and the debounce timer targets it —
// so there are no locks and no data races. The class is `@unchecked Sendable`
// because that confinement is enforced by construction, not by the type system.
//
// This file imports CoreServices/AppKit-family APIs and therefore lives in the
// macOS app target, never in portable PlayerCore.
import CoreServices
import Foundation

/// Watches library roots via FSEvents and emits a debounced, coalesced set of
/// roots to reconcile. See the file header for the threading contract.
public final class FolderWatcher: FolderWatching, @unchecked Sendable {
    private let onRootsChanged: @Sendable (Set<String>) -> Void
    private let latency: CFTimeInterval
    private let queue: DispatchQueue

    // Everything below is confined to `queue`.
    private var stream: FSEventStreamRef?
    private var currentRoots: [String] = []
    private var coalescer: PathEventCoalescer
    private var flushTimer: DispatchSourceTimer?

    /// - Parameters:
    ///   - onRootsChanged: invoked (off the main thread) with the set of root
    ///     paths whose contents changed, already debounced and coalesced.
    ///   - debounceInterval: quiet window before a flush fires (default 0.5s).
    ///   - maxCoalesceInterval: storm ceiling so a continuous burst still flushes.
    ///   - latency: FSEvents' own coalescing latency (default 0.3s).
    public init(
        onRootsChanged: @escaping @Sendable (Set<String>) -> Void,
        debounceInterval: TimeInterval = 0.5,
        maxCoalesceInterval: TimeInterval = 2.0,
        latency: TimeInterval = 0.3
    ) {
        self.onRootsChanged = onRootsChanged
        self.latency = latency
        coalescer = PathEventCoalescer(
            debounceInterval: debounceInterval,
            maxCoalesceInterval: maxCoalesceInterval
        )
        queue = DispatchQueue(label: "com.example.macamp.folderwatcher", qos: .utility)
    }

    deinit {
        // Last reference is being released: no other thread holds `self`, so the
        // queue is quiescent and tearing the stream down here is race-free. This
        // also guarantees no FSEvents callback fires after dealloc.
        teardown()
    }

    // MARK: FolderWatching

    public func startWatching(_ roots: [URL]) {
        let paths = roots.map(\.path)
        queue.async { [self] in
            configureStream(paths: paths)
        }
    }

    public func updateRoots(_ roots: [URL]) {
        startWatching(roots)
    }

    public func stopWatching() {
        queue.async { [self] in
            teardown()
        }
    }

    // MARK: Stream lifecycle (queue-confined)

    private func configureStream(paths: [String]) {
        teardown()
        currentRoots = paths
        guard !currentRoots.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot
        )
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.eventCallback,
            &context,
            currentRoots as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            return
        }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
    }

    private func teardown() {
        cancelFlushTimer()
        coalescer.drain()
        currentRoots = []
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    // MARK: Event handling (queue-confined)

    /// Records a batch of changed paths and (re)arms the debounce timer.
    fileprivate func handleEvents(_ paths: [String]) {
        coalescer.record(
            changedPaths: paths,
            roots: currentRoots,
            at: ProcessInfo.processInfo.systemUptime
        )
        armFlushTimer()
    }

    private func armFlushTimer() {
        guard let delay = coalescer.timeUntilDue(at: ProcessInfo.processInfo.systemUptime) else {
            cancelFlushTimer()
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            self?.flush()
        }
        flushTimer?.cancel()
        flushTimer = timer
        timer.resume()
    }

    private func flush() {
        guard let roots = coalescer.drainIfDue(at: ProcessInfo.processInfo.systemUptime) else {
            armFlushTimer() // not quiet yet — more events arrived; re-arm
            return
        }
        cancelFlushTimer()
        guard !roots.isEmpty else { return }
        onRootsChanged(roots)
    }

    private func cancelFlushTimer() {
        flushTimer?.cancel()
        flushTimer = nil
    }

    // MARK: FSEvents C trampoline

    /// Non-capturing C callback: recovers the watcher from `info` (passed
    /// unretained in the stream context) and forwards the changed paths. The
    /// stream is always stopped+invalidated before the watcher deallocs, so the
    /// unretained pointer is never dangling when this fires.
    private static let eventCallback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
        guard let info, count > 0 else { return }
        let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
        watcher.handleEvents(FolderWatcher.paths(from: eventPaths))
    }

    /// Bridges the `UseCFTypes` event-paths argument (a `CFArray` of `CFString`)
    /// into `[String]` without a force cast.
    private static func paths(from eventPaths: UnsafeMutableRawPointer) -> [String] {
        let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
        return (cfArray as NSArray).compactMap { $0 as? String }
    }
}
