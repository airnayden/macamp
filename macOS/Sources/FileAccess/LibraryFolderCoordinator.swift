import Foundation
import Observation
import Persistence
import Services
import ViewModels

/// Owns every configured-root side effect: watcher retargeting, scan/reconcile,
/// sidebar projection, library projection, karaoke-ready resync, revision signal,
/// and user feedback. Views request operations but never duplicate these writes.
@MainActor
@Observable
public final class LibraryFolderCoordinator {
    /// Shared folder nodes rendered by the main sidebar.
    public let sidebar: FolderSidebarViewModel
    /// Live state of the import currently running, for the import-progress UI.
    /// Fed by every scan this coordinator drives, plus the watcher-triggered
    /// rescans it attaches in ``startWatchingAndScheduleCatchUp()``.
    public let importProgress: ImportProgressModel
    /// Monotone signal emitted after all library projections have refreshed.
    public private(set) var revision = 0
    /// `false` until the launch catch-up scan has landed, so background work that
    /// must not compete with it for file I/O can stand down during launch and run
    /// normally on every later refresh.
    public private(set) var launchCatchUpComplete = false

    @ObservationIgnored private let access: LibraryAccessController
    @ObservationIgnored private let scanner: any LibraryScanning
    @ObservationIgnored private let watchService: LibraryWatchService
    @ObservationIgnored private let toast: ToastManager
    /// Scopes every ``FolderSidebarViewModel/refresh(roots:profileId:)`` to the live
    /// profile, so the tree's expansion + selection persist under the right key.
    @ObservationIgnored private let activeProfileId: @MainActor () -> Int64
    @ObservationIgnored private var contentRefresh: @MainActor @Sendable () async -> Void = {}
    @ObservationIgnored private var operationTask: Task<Void, Never>?

    public init(
        access: LibraryAccessController,
        scanner: any LibraryScanning,
        watchService: LibraryWatchService,
        sidebar: FolderSidebarViewModel,
        toast: ToastManager,
        importProgress: ImportProgressModel = ImportProgressModel(),
        activeProfileId: @escaping @MainActor () -> Int64 = { ProfileRecord.guestID }
    ) {
        self.access = access
        self.scanner = scanner
        self.watchService = watchService
        self.sidebar = sidebar
        self.toast = toast
        self.importProgress = importProgress
        self.activeProfileId = activeProfileId
    }

    /// Completes composition after `AppEnvironment` has initialized all projections.
    public func connect(
        contentRefresh: @escaping @MainActor @Sendable () async -> Void
    ) {
        self.contentRefresh = contentRefresh
        access.setOnRootsChanged { [weak self] roots, change in
            self?.rootsDidChange(roots, change: change)
        }
        importProgress.onIncrementalRefresh = { [weak self] in
            guard let self else { return }
            await refreshProjections()
        }
    }

    /// Re-probes TCC status, rescans every configured root, then refreshes once.
    public func refreshLibrary() {
        access.refreshAccess()
        let roots = access.roots.map(\.url)
        schedule(.refresh(roots: roots, showsFeedback: true))
    }

    /// Refreshes profile-scoped projections without initiating another scan.
    public func refreshProfileScope() {
        let roots = access.roots.map(\.url)
        watchService.updateRoots(roots)
        schedule(.projection(roots: roots))
    }

    /// Rescans the newly active profile's roots and refreshes scoped projections.
    public func reconcileProfileScope() {
        let roots = access.roots.map(\.url)
        watchService.updateRoots(roots)
        schedule(.refresh(roots: roots, showsFeedback: false))
    }

    /// Imports a drop without double-scanning roots: root scans stay owned by the
    /// roots-change callback; only loose files use the scanner directly here.
    public func importDrop(_ plan: DropImportPlan) async {
        for root in plan.roots {
            access.addRoot(root)
        }
        await waitForIdle()
        guard !plan.looseFiles.isEmpty else { return }
        await scan(.files(plan.looseFiles))
        schedule(.projection(roots: access.roots.map(\.url)))
        await waitForIdle()
    }

    /// Publishes the stored projections for the configured roots without scanning.
    ///
    /// Deliberately not ``refreshProfileScope()``: that also retargets the watcher,
    /// which must not happen before ``startWatchingAndScheduleCatchUp()`` starts it.
    public func publishProjections() {
        schedule(.projection(roots: access.roots.map(\.url)))
    }

    /// Starts FSEvents and queues the launch catch-up, without awaiting it.
    ///
    /// The caller decides whether to wait: ``waitForIdle()`` is still the seam for
    /// anyone who needs the scan to have landed.
    public func startWatchingAndScheduleCatchUp() async {
        await watchService.attach(progress: importProgress)
        watchService.start()
        schedule(.refresh(roots: access.roots.map(\.url), showsFeedback: false))
    }

    /// Latches ``launchCatchUpComplete``. Called once, by the launch sequence, after
    /// its catch-up scan has landed.
    public func markLaunchCatchUpComplete() {
        launchCatchUpComplete = true
    }

    /// Test/synchronization seam: returns after every operation queued so far.
    public func waitForIdle() async {
        await operationTask?.value
    }

    private func rootsDidChange(_ roots: [URL], change: LibraryRootChange) {
        watchService.updateRoots(roots)
        schedule(.rootsChanged(roots: roots, change: change))
    }

    private func schedule(_ operation: Operation) {
        let previous = operationTask
        operationTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            await perform(operation)
        }
    }

    private func perform(_ operation: Operation) async {
        let roots = operation.roots
        await watchService.reconcile(
            roots: operation.scanPaths,
            removedRoots: operation.removedPaths
        )
        await sidebar.refresh(roots: roots, profileId: activeProfileId())
        await contentRefresh()
        revision &+= 1
        showFeedback(for: operation)
    }

    /// Draining the event stream is equivalent to `scanner.scan(_:)` — the summary
    /// stays discarded exactly as before, the chunk events are the new part.
    private func scan(_ request: ScanRequest) async {
        for await event in scanner.events(for: request) {
            await importProgress.apply(event)
        }
    }

    /// Rebuilds the sidebar and library projections from the configured roots,
    /// so a folder whose first chunk landed appears while the import is still
    /// running. Throttled by ``ImportProgressModel``, which owns the cadence.
    private func refreshProjections() async {
        await sidebar.refresh(roots: access.roots.map(\.url), profileId: activeProfileId())
        await contentRefresh()
    }

    private func showFeedback(for operation: Operation) {
        switch operation {
        case let .rootsChanged(_, .added(url)):
            toast.show(text: String(localized: FileAccessStrings.folderAdded(url.lastPathComponent)))
        case let .rootsChanged(_, .removed(url)):
            toast.show(text: String(localized: FileAccessStrings.folderRemoved(url.lastPathComponent)))
        case .refresh(_, true):
            toast.show(text: String(localized: FileAccessStrings.libraryRefreshed), icon: "arrow.clockwise.circle.fill")
        case .refresh(_, false), .projection:
            break
        }
    }
}

private extension LibraryFolderCoordinator {
    enum Operation {
        case rootsChanged(roots: [URL], change: LibraryRootChange)
        case refresh(roots: [URL], showsFeedback: Bool)
        case projection(roots: [URL])

        var roots: [URL] {
            switch self {
            case let .rootsChanged(roots, _), let .refresh(roots, _), let .projection(roots): roots
            }
        }

        var scanPaths: Set<String> {
            switch self {
            case let .rootsChanged(_, .added(url)):
                [url.path]
            case let .refresh(roots, _):
                Set(roots.map(\.path))
            case .rootsChanged(_, .removed), .projection:
                []
            }
        }

        var removedPaths: Set<String> {
            guard case let .rootsChanged(_, .removed(url)) = self else { return [] }
            return [url.path]
        }
    }
}
