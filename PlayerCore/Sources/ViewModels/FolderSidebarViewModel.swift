// FolderSidebarViewModel — the dynamic folder sidebar: one node per library-root
// folder (Task 13) plus the lazily-materialized subfolder tree beneath it (Task 7).
//
// Every node carries a STABLE id derived from its path (an FNV-1a hash,
// deterministic across launches — `String.hashValue` is per-process salted and
// would break a persisted `.folder(rootId:)` selection), its display name, whether
// it holds subfolders, its depth, and whether every track under its root is
// unavailable. The same hash is applied to ANY path, not just roots, so a nested
// folder is addressable by the very same `.folder(rootId:)` destination a root is.
//
// Roots come IN as `[URL]` (the macOS `LibraryRootsStore`) so this stays AppKit-free
// (PlayerCore portability invariant); the view layer maps a selected `rootId` back
// to a path via ``FolderSidebarViewModel/path(forId:)`` (`rootPath(forId:)` is the
// retained spelling used by `MainWindowActions`). Subfolders are derived ENTIRELY
// from `track.filePath` through `TrackRepository.childFolders` — this view model
// NEVER walks the filesystem. Counts and child levels are read OFF the main actor
// (`Task.detached`), never blocking it on a GRDB reader (the library QoS invariant).
//
// The expansion/selection state persists through an injected ``FolderTreePersistence``
// closure pair keyed by profile id, so the shell can back it with `UserDefaults`
// while PlayerCore stays free of any storage dependency.
import Foundation
import Models
import Observation
import Persistence

// MARK: - View model

/// Builds nodes for configured library roots and the lazily loaded subfolder
/// levels beneath them.
@MainActor
@Observable
public final class FolderSidebarViewModel {
    /// The library-root nodes, ordered by ``sort``.
    ///
    /// `internal(set)` rather than `private(set)` so ``resort()`` — which lives in
    /// `FolderSidebarViewModel+Sort.swift` for this file's line budget — can reorder
    /// them; Swift scopes `private` to the declaring file.
    public internal(set) var nodes: [FolderSidebarNode] = []

    /// The flattened rows the sidebar renders: each root followed by the
    /// materialized subtree beneath it while expanded. Under a non-empty
    /// ``filterText`` it is instead the flattened match set plus every ancestor
    /// needed to reach it.
    public internal(set) var visibleNodes: [FolderSidebarNode] = []

    /// The folder paths the user has expanded, persisted per profile.
    public internal(set) var expandedPaths: Set<String> = []

    /// Ancestors the active filter had to open to reveal a match. Kept apart from
    /// ``expandedPaths`` so clearing the filter restores the user's own expansion.
    var filterExpandedPaths: Set<String> = []

    /// The paths matching the active filter, or `nil` when no filter is active.
    var filterMatchPaths: Set<String>?

    /// How every level of the tree is ordered. Assigning re-orders the already
    /// materialized tree in memory — ``resort()`` issues no query.
    ///
    /// Equality-guarded because `@Observable` publishes same-value writes, and the
    /// shell re-applies this from `AppSettings` on every settings change.
    public var sort: FolderSort = .default {
        didSet {
            guard sort != oldValue else { return }
            resort()
        }
    }

    /// The sidebar's folder filter. Assigning re-derives ``visibleNodes`` in the
    /// background; ``setFilter(_:)`` is the awaitable spelling.
    public var filterText: String = "" {
        didSet {
            guard filterText != oldValue else { return }
            filterTask?.cancel()
            filterTask = Task { [weak self] in await self?.applyFilter() }
        }
    }

    @ObservationIgnored let repository: any FolderTreeReading
    @ObservationIgnored let persistence: FolderTreePersistence
    @ObservationIgnored private var knownRootPaths: [String] = []
    @ObservationIgnored private var hasHydrated = false
    @ObservationIgnored private var filterTask: Task<Void, Never>?

    /// The active profile every ``FolderTreeReading/childFolders(profileId:parentPath:)``
    /// read and every persistence round trip is scoped to.
    @ObservationIgnored private(set) var activeProfileId: Int64 = ProfileRecord.guestID

    /// Bumped by every ``refresh(roots:profileId:)`` so a child load started against
    /// the previous tree is discarded rather than landing in the new one.
    @ObservationIgnored var generation: Int = 0

    /// One loaded level of subfolders per parent path — the lazy tree's cache,
    /// dropped wholesale by each refresh so a mid-import rescan surfaces new folders.
    @ObservationIgnored var childrenCache: [String: [FolderSidebarNode]] = [:]

    /// In-flight child loads, so concurrent expansions of the same folder issue
    /// exactly one ``FolderTreeReading/childFolders(profileId:parentPath:)`` call.
    @ObservationIgnored var childLoads: [String: Task<[FolderSidebarNode], Never>] = [:]

    /// Whether a path was observed to hold subfolders — seeded for each root by
    /// ``rebuildRoots(_:)``'s probe and refined by every child load. It survives the
    /// cache drop, so a root is probed once and its chevron then stays accurate
    /// across refreshes; ``resetTree()`` clears it, so a profile switch re-probes.
    @ObservationIgnored var knownHasChildren: [String: Bool] = [:]

    /// Every materialized node by path, and its id→path index.
    @ObservationIgnored var nodesByPath: [String: FolderSidebarNode] = [:]
    @ObservationIgnored private var pathsById: [Int64: String] = [:]
    @ObservationIgnored private var persistedSelection: FolderTreeSelection?

    public init(
        repository: any FolderTreeReading,
        persistence: FolderTreePersistence = .ephemeral
    ) {
        self.repository = repository
        self.persistence = persistence
    }

    /// Rebuilds ``nodes`` from configured roots that own tracks, then
    /// re-materializes the expanded subtree.
    ///
    /// A change of `profileId` — or the first call — hydrates the expansion and
    /// selection state for that profile from ``FolderTreePersistence``. The children
    /// cache and the id→path registry are pruned to the surviving roots, and the
    /// persisted selection's id→path pair is seeded back into the registry with its
    /// ancestor chain expanded, so a restored `.folder(rootId:)` naming a subfolder
    /// resolves even though only roots have been materialized.
    public func refresh(roots: [URL], profileId: Int64 = ProfileRecord.guestID) async {
        if profileId != activeProfileId || !hasHydrated {
            activeProfileId = profileId
            hasHydrated = true
            resetTree()
            hydrateFromPersistence()
        }
        generation &+= 1
        childrenCache.removeAll()
        for task in childLoads.values {
            task.cancel()
        }
        childLoads.removeAll()
        await rebuildRoots(roots)
        pruneToKnownRoots()
        seedPersistedSelection()
        await materializeExpandedPaths()
        rebuildVisibleNodes()
    }

    /// Resolves a folder node's `rootId` back to its filesystem path — for any
    /// materialized node, root or nested.
    public func path(forId rootId: Int64) -> String? {
        pathsById[rootId]
    }

    /// The retained spelling of ``path(forId:)`` used by the macOS shell. It now
    /// resolves nested folders too, so a `.folder(rootId:)` selection deeper than a
    /// root maps to the right browse path.
    public func rootPath(forId rootId: Int64) -> String? {
        path(forId: rootId)
    }

    /// Records the sidebar's current folder selection so a later launch — or a
    /// profile switch back — can resolve that `.folder(rootId:)` to a subfolder path.
    public func noteSelection(rootId: Int64) {
        guard let path = path(forId: rootId) else { return }
        let selection = FolderTreeSelection(rootId: rootId, path: path)
        guard selection != persistedSelection else { return }
        persistedSelection = selection
        persist()
    }

    /// Clears the recorded folder selection (the sidebar moved to a fixed section).
    public func clearSelection() {
        guard persistedSelection != nil else { return }
        persistedSelection = nil
        persist()
    }

    /// Drops any queued background re-filter, so ``setFilter(_:)`` can run the
    /// derivation itself and callers observe a settled result.
    func cancelPendingFilter() {
        filterTask?.cancel()
        filterTask = nil
    }

    /// Writes the current expansion + selection state back through the seam.
    func persist() {
        persistence.save(activeProfileId, FolderTreeState(
            expandedPaths: expandedPaths.sorted(),
            selection: persistedSelection
        ))
    }

    /// Indexes a node so ``path(forId:)`` and the tree walk can find it.
    func register(_ node: FolderSidebarNode) {
        nodesByPath[node.path] = node
        pathsById[node.rootId] = node.path
    }

    /// Whether `path` is one of the retained roots or lives beneath one.
    func isUnderKnownRoot(_ path: String) -> Bool {
        knownRootPaths.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private func rebuildRoots(_ roots: [URL]) async {
        let paths = roots.map(Self.normalizedPath)
        var built: [FolderSidebarNode] = []
        var retained: [String] = []
        for path in paths {
            let summary = await summary(forRoot: path)
            guard summary.hasTracks else { continue }
            if knownHasChildren[path] == nil {
                knownHasChildren[path] = await hasSubfolders(forRoot: path)
            }
            retained.append(path)
            built.append(FolderSidebarNode(
                rootId: Self.stableRootId(forPath: path),
                path: path,
                name: Self.displayName(forPath: path),
                isMissing: summary.isFullyUnavailable,
                hasChildren: knownHasChildren[path] ?? true,
                depth: 0,
                newestDateAdded: summary.newestDateAdded
            ))
        }
        knownRootPaths = retained
        nodes = sorted(built)
        for node in built {
            register(node)
        }
    }

    /// Drops every cached child level, registry entry and expansion that no longer
    /// sits beneath a surviving root — the removed-root / profile-switch prune.
    private func pruneToKnownRoots() {
        childrenCache = childrenCache.filter { isUnderKnownRoot($0.key) }
        knownHasChildren = knownHasChildren.filter { isUnderKnownRoot($0.key) }
        nodesByPath = nodesByPath.filter { isUnderKnownRoot($0.key) }
        pathsById = pathsById.filter { isUnderKnownRoot($0.value) }
        expandedPaths = expandedPaths.filter(isUnderKnownRoot)
        filterExpandedPaths = filterExpandedPaths.filter(isUnderKnownRoot)
        if let selection = persistedSelection, !isUnderKnownRoot(selection.path) {
            persistedSelection = nil
        }
    }

    private func seedPersistedSelection() {
        guard let selection = persistedSelection else { return }
        pathsById[selection.rootId] = selection.path
    }

    /// Loads the child level of every expanded folder — plus the ancestor chain of
    /// the persisted selection — parents before children, so each level's nodes are
    /// registered before the next one is asked for.
    private func materializeExpandedPaths() async {
        if let selection = persistedSelection {
            expandedPaths.formUnion(Self.ancestorChain(of: selection.path, roots: knownRootPaths))
        }
        for path in expandedPaths.sorted(by: { $0.count < $1.count }) {
            await loadChildren(of: path)
        }
    }

    private func hydrateFromPersistence() {
        let state = persistence.load(activeProfileId)
        expandedPaths = Set(state.expandedPaths)
        persistedSelection = state.selection
    }

    private func resetTree() {
        filterTask?.cancel()
        filterTask = nil
        for task in childLoads.values {
            task.cancel()
        }
        childLoads.removeAll()
        childrenCache.removeAll()
        knownHasChildren.removeAll()
        nodesByPath.removeAll()
        pathsById.removeAll()
        expandedPaths.removeAll()
        filterExpandedPaths.removeAll()
        filterMatchPaths = nil
        persistedSelection = nil
        knownRootPaths.removeAll()
        nodes = []
        visibleNodes = []
    }

    private func summary(forRoot path: String) async -> RootTrackSummary {
        let repository = repository
        return await Task.detached {
            (try? repository.rootSummary(rootPath: path))
                ?? RootTrackSummary(total: 0, present: 0, missing: 0, externalOffline: 0)
        }.value
    }

    /// Whether a root holds subfolders, read off the main actor beside its tally.
    ///
    /// A probe that cannot answer falls back to `true`: an extra chevron on a leaf
    /// root self-heals the moment the user opens it, whereas a missing one hides a
    /// whole subtree.
    private func hasSubfolders(forRoot path: String) async -> Bool {
        let repository = repository
        let profileId = activeProfileId
        return await Task.detached {
            (try? repository.hasSubfolders(profileId: profileId, rootPath: path)) ?? true
        }.value
    }
}

extension FolderSidebarViewModel {
    /// A deterministic, non-negative id for a folder path (FNV-1a, stable across
    /// launches so a persisted `.folder(rootId:)` selection keeps resolving).
    ///
    /// `nonisolated` because it is a pure function of its argument: a caller off the
    /// main actor (the shell's persistence wiring, a test fixture) must be able to
    /// derive the same id without hopping.
    public nonisolated static func stableRootId(forPath path: String) -> Int64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return Int64(hash & 0x7FFF_FFFF_FFFF_FFFF)
    }

    static func normalizedPath(_ url: URL) -> String {
        url.path
    }

    static func displayName(forPath path: String) -> String {
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? path : last
    }

    /// The folders between `path`'s owning root and `path` itself, root first and
    /// `path` excluded — the chain that must be expanded for `path` to be visible.
    static func ancestorChain(of path: String, roots: [String]) -> [String] {
        guard let root = roots.first(where: { path == $0 || path.hasPrefix($0 + "/") }),
              path != root
        else { return [] }
        var chain = [root]
        var current = root
        for segment in path.dropFirst(root.count + 1).split(separator: "/").dropLast() {
            current += "/" + segment
            chain.append(current)
        }
        return chain
    }
}
