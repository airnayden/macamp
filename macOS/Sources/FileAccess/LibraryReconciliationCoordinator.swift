// LibraryReconciliationCoordinator — turns a debounced "these roots changed"
// signal from the ``FolderWatcher`` into a reconciliation pass that feeds the two
// PlayerCore services that own library truth:
//
//   * `Services.LibraryScanner` (Task 13) — re-scans the changed roots. Its
//     fingerprint skip (mtime + size) means a re-scan only re-reads files that
//     actually changed, so reacting to a folder edit is cheap even at 100k tracks.
//   * `Persistence.AvailabilityReconciler` (Task 14) — re-derives every track's
//     availability (present / missing / externalOffline) WITHOUT deleting rows, so
//     a file that vanished from a watched root is marked missing, never dropped.
//
// An `actor` serialises passes: overlapping change bursts coalesce into one
// in-flight pass plus a single queued follow-up, so a long scan never stacks up
// behind a flurry of FSEvents flushes. The watcher's synchronous, `Sendable`
// callback bridges in through the `nonisolated` ``handleRootsChanged(_:)``.
//
// `LibraryWatchService` is the one-call composition root (store + watcher +
// coordinator) that Task 30 instantiates from `AppEnvironment` and embeds beside
// `LibraryFoldersView` in Preferences.
import Foundation
import Persistence
import Services
import ViewModels

// MARK: - LibraryReconciliationCoordinator

/// Serialises root re-scans + availability reconciliation in response to folder
/// changes. See the file header for how it feeds the scanner and reconciler.
public actor LibraryReconciliationCoordinator {
    private let scanner: any LibraryScanning
    private let reconciler: any AvailabilityReconciling
    private var queuedRoots: Set<String> = []
    private var queuedRemovedRoots: Set<String> = []
    private var completions: [CheckedContinuation<Void, Never>] = []
    private var isRunning = false
    private var progress: ImportProgressModel?

    /// Number of completed reconciliation passes (for tests / diagnostics).
    public private(set) var passCount = 0

    public init(scanner: any LibraryScanning, reconciler: any AvailabilityReconciling) {
        self.scanner = scanner
        self.reconciler = reconciler
    }

    /// Routes every scan this coordinator drives into `model`. Optional — with no
    /// model attached the scans run exactly as before.
    public func attach(progress model: ImportProgressModel) {
        progress = model
    }

    /// Bridges the watcher's synchronous `Sendable` callback into the actor.
    public nonisolated func handleRootsChanged(_ roots: Set<String>) {
        Task { await self.enqueue(roots: roots, removedRoots: []) }
    }

    /// Awaitable form of ``handleRootsChanged(_:)`` — returns once the resulting
    /// pass (and any follow-up coalesced into it) has finished. Used by tests.
    public func reconcile(roots: Set<String>, removedRoots: Set<String> = []) async {
        await withCheckedContinuation { continuation in
            enqueue(roots: roots, removedRoots: removedRoots, completion: continuation)
        }
    }

    private func enqueue(
        roots: Set<String>,
        removedRoots: Set<String>,
        completion: CheckedContinuation<Void, Never>? = nil
    ) {
        queuedRoots.formUnion(roots)
        queuedRemovedRoots.formUnion(removedRoots)
        if let completion { completions.append(completion) }
        guard !isRunning else { return }
        isRunning = true
        Task { await drain() }
    }

    private func drain() async {
        while !queuedRoots.isEmpty || !queuedRemovedRoots.isEmpty {
            let roots = queuedRoots
            let removedRoots = queuedRemovedRoots.subtracting(roots)
            queuedRoots.removeAll()
            queuedRemovedRoots.removeAll()
            await runPass(roots: roots, removedRoots: removedRoots)
        }
        isRunning = false
        let completed = completions
        completions.removeAll()
        completed.forEach { $0.resume() }
    }

    private func runPass(roots: Set<String>, removedRoots: Set<String>) async {
        for path in roots.sorted() {
            await scan(.directory(URL(fileURLWithPath: path)))
        }
        // Availability is library-wide, so one reconcile covers every changed
        // root. Errors are non-fatal here — a transient write failure is retried
        // on the next change.
        _ = try? reconciler.reconcile() // reconcile result intentionally discarded
        // A removed folder takes its tracks with it, unless another configured
        // folder (in any profile) still covers them. The sweep then clears
        // missing tracks left outside every folder by earlier removals.
        for path in removedRoots.sorted() {
            _ = try? reconciler.removeTracks(underRemovedRoot: path)
        }
        _ = try? reconciler.pruneOrphanedMissingTracks()
        passCount += 1
    }

    /// Draining the event stream is equivalent to `scanner.scan(_:)` — the summary
    /// stays discarded exactly as before, the chunk events are the new part.
    private func scan(_ request: ScanRequest) async {
        guard let progress else {
            _ = await scanner.scan(request)
            return
        }
        for await event in scanner.events(for: request) {
            await progress.apply(event)
        }
    }
}

// MARK: - LibraryWatchService

/// One-call composition of the roots store, the FSEvents watcher, and the
/// reconciliation coordinator. `Sendable` (all dependencies are), so it can be
/// retained by the composition root and driven from anywhere.
public final class LibraryWatchService: Sendable {
    /// The reconciliation coordinator (exposed for an explicit launch reconcile).
    public let coordinator: LibraryReconciliationCoordinator
    /// The live folder watcher.
    public let watcher: any FolderWatching

    private let store: any LibraryRootsStoring

    /// - Parameters:
    ///   - scanner: the library importer to re-scan changed roots.
    ///   - reconciler: the availability reconciler (build with `AppDatabase`).
    ///   - store: persistence for the chosen roots.
    ///   - debounceInterval: FSEvents debounce window (default 0.5s).
    public init(
        scanner: any LibraryScanning,
        reconciler: any AvailabilityReconciling,
        store: any LibraryRootsStoring = UserDefaultsLibraryRootsStore(),
        debounceInterval: TimeInterval = 0.5
    ) {
        let coordinator = LibraryReconciliationCoordinator(scanner: scanner, reconciler: reconciler)
        self.coordinator = coordinator
        self.store = store
        watcher = FolderWatcher(
            onRootsChanged: { roots in coordinator.handleRootsChanged(roots) },
            debounceInterval: debounceInterval
        )
    }

    /// Begins watching the persisted roots.
    public func start() {
        watcher.startWatching(store.load())
    }

    /// Retargets the watcher after the user adds/removes a root.
    public func updateRoots(_ roots: [URL]) {
        watcher.updateRoots(roots)
    }

    /// Stops watching and releases the event stream.
    public func stop() {
        watcher.stopWatching()
    }

    /// Triggers an immediate scan + reconcile of every persisted root (e.g. once
    /// at launch to catch changes made while the app was closed).
    public func reconcileAll() {
        let paths = Set(store.load().map(\.path))
        guard !paths.isEmpty else { return }
        coordinator.handleRootsChanged(paths)
    }

    /// Awaitable scan/reconcile used by user-driven folder operations so UI
    /// projections refresh only after the database changes have landed.
    public func reconcile(roots: Set<String>, removedRoots: Set<String> = []) async {
        await coordinator.reconcile(roots: roots, removedRoots: removedRoots)
    }

    /// Routes every scan this service drives — including watcher-triggered
    /// rescans — into `progress`. Await it before ``start()`` so the first
    /// FSEvents flush is already covered.
    public func attach(progress: ImportProgressModel) async {
        await coordinator.attach(progress: progress)
    }
}
