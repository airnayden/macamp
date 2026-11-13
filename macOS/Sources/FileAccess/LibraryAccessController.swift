// LibraryAccessController — the first-run (and ongoing) folder-access flow.
//
// The user picks library folders via `NSOpenPanel`; we probe each for
// readability and persist the chosen paths. macOS is not sandboxed, so picking a
// folder grants access immediately — but a *protected* location (Desktop,
// Documents, an external volume) can still be gated by TCC ("Files and Folders"
// privacy), and the user can revoke access later. This controller handles denial
// GRACEFULLY: it never crashes, it surfaces a per-root status, and it offers a
// recovery affordance that re-runs the picker or opens the relevant System
// Settings pane. Nothing here is fatal.
//
// All side-effecting OS interactions (the open panel, readability probing, opening
// System Settings) are injected protocol seams so the flow is unit-testable with
// fakes; the concrete app wiring lives in `LibraryAccessSeams.swift`.
//
// `@Observable` so SwiftUI (``LibraryFoldersView``) re-renders as roots and their
// access states change; every injected dependency is `@ObservationIgnored`.
import Darwin
import Foundation
import Models
import Observation

// MARK: - FolderAccessStatus

/// The access state of one library root, as last probed.
public enum FolderAccessStatus: Sendable, Equatable {
    /// Readable — reconciliation and playback can use it.
    case accessible
    /// Exists but unreadable (TCC denied / permissions). Recoverable.
    case denied
    /// No longer present (deleted, or an unmounted external volume).
    case missing
}

// MARK: - LibraryRoot

/// A chosen library root folder plus its most recently probed access status.
public struct LibraryRoot: Identifiable, Sendable, Equatable {
    public let url: URL
    public var status: FolderAccessStatus

    public var id: String {
        url.path
    }

    public init(url: URL, status: FolderAccessStatus) {
        self.url = url
        self.status = status
    }
}

/// The semantic mutation accompanying an updated configured-root set.
public enum LibraryRootChange: Sendable, Equatable {
    case added(URL)
    case removed(URL)
}

// MARK: - LibraryRootRejection

/// Why ``LibraryAccessController/addRoot(_:)`` refused a folder.
public enum LibraryRootRejectionReason: Sendable, Equatable {
    /// The folder is inside MacAMP's own Application Support or Caches container —
    /// adding it would let the scan re-import app-generated files (e.g. the GRDB
    /// store), so it is not a valid music-library root.
    case appInternalDirectory
    /// The folder is equal to, inside, or an ancestor of the current karaoke
    /// instrumental cache directory (which the user may have moved outside the app's
    /// own containers) — scanning it would re-import the app's rendered instrumentals.
    case karaokeCacheDirectory

    public var message: LocalizedStringResource {
        switch self {
        case .appInternalDirectory:
            FileAccessStrings.rejectedAppInternal
        case .karaokeCacheDirectory:
            FileAccessStrings.rejectedKaraokeCache
        }
    }
}

/// A folder ``LibraryAccessController/addRoot(_:)`` declined, with the reason.
public struct LibraryRootRejection: Sendable, Equatable {
    public let url: URL
    public let reason: LibraryRootRejectionReason

    public init(url: URL, reason: LibraryRootRejectionReason) {
        self.url = url
        self.reason = reason
    }
}

// MARK: - LibraryAccessControlling

/// The folder-access flow seam: choose, list, probe, remove roots, and recover
/// from a denial. `@MainActor` because it drives UI and the open panel.
@MainActor
public protocol LibraryAccessControlling: AnyObject {
    /// The chosen roots with their last-probed status.
    var roots: [LibraryRoot] { get }
    /// Presents the folder picker and adds whatever the user chooses.
    func requestAccess() async
    /// Adds a single root (deduplicated, probed, persisted).
    func addRoot(_ url: URL)
    /// Removes a root and persists the change.
    func removeRoot(_ root: LibraryRoot)
    /// Re-probes every root's access status (e.g. after returning from Settings).
    func refreshAccess()
    /// Opens the System Settings pane where the user can grant access.
    func openSystemSettings()
}

// MARK: - LibraryAccessController

/// The production ``LibraryAccessControlling``. See the file header for the flow.
@MainActor
@Observable
public final class LibraryAccessController: LibraryAccessControlling {
    /// The chosen roots, each carrying its last-probed access status.
    public private(set) var roots: [LibraryRoot] = []

    /// The most recent folder ``addRoot(_:)`` declined, or `nil` if the last add
    /// succeeded. Observable so the UI can surface the localized reason.
    public private(set) var lastRejection: LibraryRootRejection?

    @ObservationIgnored private let store: any LibraryRootsStoring
    @ObservationIgnored private let picker: any FolderPicking
    @ObservationIgnored private let probe: any FileAccessProbing
    @ObservationIgnored private let settings: any SystemSettingsOpening
    @ObservationIgnored private var onRootsChanged: @MainActor @Sendable ([URL], LibraryRootChange) -> Void
    @ObservationIgnored private let karaokeCacheDirectory: @Sendable () -> URL?

    /// - Parameters:
    ///   - store: persistence for the chosen paths.
    ///   - picker: the folder picker (live `NSOpenPanel` or a fake).
    ///   - probe: readability probing (live `FileManager` or a fake).
    ///   - settings: opens the privacy pane on denial.
    ///   - onRootsChanged: notified with the new path set whenever roots change,
    ///     so the watcher can be retargeted.
    ///   - karaokeCacheDirectory: the CURRENT karaoke instrumental cache directory
    ///     (read from the composition root's lock box), so a chosen root that overlaps
    ///     it is rejected. `nil` ⇒ no cache directory to protect.
    public init(
        store: any LibraryRootsStoring = UserDefaultsLibraryRootsStore(),
        picker: any FolderPicking = NSOpenPanelFolderPicker(),
        probe: any FileAccessProbing = FileManagerAccessProbe(),
        settings: any SystemSettingsOpening = SystemSettingsLauncher(),
        onRootsChanged: @escaping @MainActor @Sendable ([URL], LibraryRootChange) -> Void = { _, _ in },
        karaokeCacheDirectory: @escaping @Sendable () -> URL? = { nil }
    ) {
        self.store = store
        self.picker = picker
        self.probe = probe
        self.settings = settings
        self.onRootsChanged = onRootsChanged
        self.karaokeCacheDirectory = karaokeCacheDirectory
        // Seed optimistically WITHOUT touching the filesystem: the probe runs
        // `contentsOfDirectory`, which hangs indefinitely on wedged/slow I/O
        // (observed live: a stuck ~/Downloads froze the app at the splash).
        // This runs on the main thread during launch, so statuses are corrected
        // by the off-main probe kicked below instead.
        loadStoredRoots()
        refreshAccess()
    }

    /// Roots that exist but are currently unreadable — the set the recovery UI
    /// nudges the user to fix.
    public var deniedRoots: [LibraryRoot] {
        roots.filter { $0.status == .denied }
    }

    /// Whether any chosen root is currently unreadable.
    public var hasDeniedAccess: Bool {
        !deniedRoots.isEmpty
    }

    public func requestAccess() async {
        let picked = await picker.pickFolders()
        for url in picked {
            addRoot(url)
        }
    }

    public func addRoot(_ url: URL) {
        let canonical = Self.canonicalRootURL(url)
        if let reason = rejectionReason(for: canonical) {
            lastRejection = LibraryRootRejection(url: canonical, reason: reason)
            return
        }
        lastRejection = nil
        guard !roots.contains(where: { Self.canonicalRootURL($0.url) == canonical }) else { return }
        roots.append(LibraryRoot(url: canonical, status: .accessible))
        persistAndNotify(change: .added(canonical))
        refreshAccess()
    }

    /// Rejects a chosen root that must never be scanned: MacAMP's own Application
    /// Support / Caches containers (the GRDB store, the default instrumental cache),
    /// or any folder overlapping the CURRENT karaoke cache directory — which the user
    /// may have relocated OUTSIDE those containers, so it needs its own accurate
    /// reason rather than the "app-internal" one. Behaviourally covered by the
    /// folder-picker XCUITest.
    func rejectionReason(for url: URL) -> LibraryRootRejectionReason? {
        if CacheDirectoryOverlapPolicy.isSystemInternalLocation(url) {
            return .appInternalDirectory
        }
        if let cacheDirectory = karaokeCacheDirectory(),
           CacheDirectoryOverlapPolicy.overlap(cacheDirectory: cacheDirectory, roots: [url]) != nil
        {
            return .karaokeCacheDirectory
        }
        return nil
    }

    public func removeRoot(_ root: LibraryRoot) {
        let canonical = Self.canonicalRootURL(root.url)
        let before = roots.count
        roots.removeAll { Self.canonicalRootURL($0.url) == canonical }
        guard roots.count != before else { return }
        persistAndNotify(change: .removed(canonical))
    }

    /// Removes the configured root matching `path` after normalising both sides.
    /// Returns `false` rather than silently presenting a successful UI action when
    /// the sidebar path no longer corresponds to a configured root.
    @discardableResult
    public func removeRoot(matchingPath path: String) -> Bool {
        let canonicalPath = Self.canonicalRootURL(URL(fileURLWithPath: path)).path
        guard let root = roots.first(where: { Self.canonicalRootURL($0.url).path == canonicalPath }) else {
            return false
        }
        removeRoot(root)
        return true
    }

    /// Reloads the roots after the shared GRDB store changes profile scope.
    public func reloadRoots() {
        loadStoredRoots()
        lastRejection = nil
        refreshAccess()
    }

    /// Installs the app-wide roots-change owner after the composition graph exists.
    public func setOnRootsChanged(
        _ handler: @escaping @MainActor @Sendable ([URL], LibraryRootChange) -> Void
    ) {
        onRootsChanged = handler
    }

    /// Probes run OFF the main actor: the production probe enumerates the
    /// directory, which blocks arbitrarily long on unreachable volumes or stuck
    /// I/O. Results are merged by URL so roots added or removed mid-probe keep
    /// their state.
    public func refreshAccess() {
        let urls = roots.map(\.url)
        guard !urls.isEmpty else { return }
        let probe = probe
        Task.detached(priority: .utility) { [weak self] in
            let statuses = urls.map { url in (url, probe.status(of: url)) }
            await self?.applyProbedStatuses(statuses)
        }
    }

    private func applyProbedStatuses(_ statuses: [(URL, FolderAccessStatus)]) {
        for (url, status) in statuses {
            guard let index = roots.firstIndex(where: { $0.url == url }) else { continue }
            roots[index] = LibraryRoot(url: url, status: status)
        }
    }

    public func openSystemSettings() {
        settings.openFilesAndFoldersPrivacy()
    }

    private func persistAndNotify(change: LibraryRootChange) {
        let urls = roots.map(\.url)
        store.save(urls)
        onRootsChanged(urls, change)
    }

    private static func canonicalRootURL(_ url: URL) -> URL {
        var candidate = url.standardizedFileURL
        var missingComponents: [String] = []
        while true {
            if let resolvedPath = realPath(candidate.path) {
                let suffix = missingComponents.reversed().joined(separator: "/")
                let canonicalPath = suffix.isEmpty
                    ? resolvedPath
                    : (resolvedPath as NSString).appendingPathComponent(suffix)
                return URL(fileURLWithPath: canonicalPath)
            }
            guard candidate.path != "/" else { return url.standardizedFileURL }
            missingComponents.append(candidate.lastPathComponent)
            candidate.deleteLastPathComponent()
        }
    }

    private static func realPath(_ path: String) -> String? {
        path.withCString { pathPointer in
            guard let resolvedPointer = Darwin.realpath(pathPointer, nil) else { return nil }
            defer { free(resolvedPointer) }
            return String(cString: resolvedPointer)
        }
    }

    private func loadStoredRoots() {
        let stored = store.load()
        var seenPaths: Set<String> = []
        let canonical = stored.compactMap { url -> URL? in
            let resolved = Self.canonicalRootURL(url)
            return seenPaths.insert(resolved.path).inserted ? resolved : nil
        }
        roots = canonical.map { LibraryRoot(url: $0, status: .accessible) }
        if stored.map(\.path) != canonical.map(\.path) {
            store.save(canonical)
        }
    }
}

// MARK: - FakeLibraryAccessControlling

/// A minimal ``LibraryAccessControlling`` double for higher-layer tests that need
/// to drive or observe access state without the real open panel or filesystem.
@MainActor
public final class FakeLibraryAccessControlling: LibraryAccessControlling {
    public private(set) var roots: [LibraryRoot]
    /// URLs the next ``requestAccess()`` will "pick".
    public var pendingPick: [URL] = []
    public private(set) var openSettingsCount = 0
    public private(set) var refreshCount = 0

    public init(roots: [LibraryRoot] = []) {
        self.roots = roots
    }

    public func requestAccess() async {
        for url in pendingPick {
            addRoot(url)
        }
        pendingPick = []
    }

    public func addRoot(_ url: URL) {
        let standardized = url.standardizedFileURL
        guard !roots.contains(where: { $0.url == standardized }) else { return }
        roots.append(LibraryRoot(url: standardized, status: .accessible))
    }

    public func removeRoot(_ root: LibraryRoot) {
        roots.removeAll { $0.id == root.id }
    }

    public func refreshAccess() {
        refreshCount += 1
    }

    public func openSystemSettings() {
        openSettingsCount += 1
    }
}
