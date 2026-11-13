// FolderOutlineViewModel — the expansion and per-level pagination state behind the
// main window's hierarchical folder browser.
//
// A `.folder` destination used to render one flat, RECURSIVE track list. It now
// renders an outline: the browsed directory's immediate subfolders first (each with
// its recursive track count), then that directory's own direct files — and a
// subfolder expands INLINE, to any depth, by the same rule applied recursively.
//
// Everything derives from `TrackRepository.childFolders` / `.tracksDirectlyIn`
// (Task 2): no filesystem walk, no migration, and every read is bounded — one
// aggregate per expanded level plus that level's own keyset pages.
//
// PAGINATION OWNERSHIP: this view model is a FIFTH window, and deliberately not a
// fifth branch of `LibraryBrowserPagination.swift`'s `hasMoreTracks` /
// `loadedTrackCount` / `loadNextPage()` triad. Those three dispatch over ONE
// window for the whole list; an outline has one window PER RENDERED LEVEL, so it
// carries its own per-level cursor, its own per-level in-flight gate, and its own
// threshold prefetch (``prefetchFilesIfNeeded(_:)``). The flat list's contract is
// untouched, and the browser routes to exactly one of the two.
import Foundation
import Models
import Observation
import Persistence

/// Lazy, unlimited-depth outline state for one browsed folder.
@MainActor
@Observable
public final class FolderOutlineViewModel {
    /// The folder the outline is rooted at — the sidebar's `.folder` selection.
    public let rootPath: String

    /// Every row above the browsed folder's own direct files: its subfolders, and
    /// the fully expanded contents of each.
    ///
    /// Split from ``rootFileRows`` because the browsed root's files are always the
    /// CONTIGUOUS TRAILING block of the outline, which is what lets the shell put
    /// them in their own `ForEach` and hang `.onMove` on that alone — drag-reorder
    /// at the root level, none anywhere else, with no index translation.
    public internal(set) var subtreeRows: [FolderOutlineRow] = []

    /// The browsed folder's own direct files, after the genre chip.
    public internal(set) var rootFileRows: [FolderOutlineFile] = []

    /// `true` while the initial level load runs.
    public private(set) var isLoading = false

    /// The genre chip, applied to the files of EVERY rendered level.
    ///
    /// CLIENT-SIDE, and bounded to each level's LOADED pages — never a second
    /// genre-aware query. A level holds at most a few hundred rows (100 per page,
    /// grown on demand), so filtering them in memory is far cheaper than paging a
    /// second cursor per level. Subfolder rows are NOT filtered: their counts are
    /// recursive aggregates, and narrowing them would need one genre-scoped
    /// aggregate per folder.
    public var genreFilter: GenreFilter = .all {
        didSet {
            guard genreFilter != oldValue else { return }
            rebuildRows()
        }
    }

    /// How the outline is ordered: the profile's own drag order, or a query-derived
    /// one. Files PAGE under it (the order is the database's); subfolders sort in
    /// memory under the comparator it implies — see `FolderOutlineViewModel+Sort.swift`.
    ///
    /// The equality guard is load-bearing, not hygiene: `@Observable` publishes
    /// same-value writes, and the shell re-applies the stored browser sort on every
    /// settings change — including the ones that only touched the sidebar tree.
    /// Without it, changing the tree's order would re-page this folder's files.
    ///
    /// Deliberately carries NO default value. A stored default completes this
    /// property's initialization before the init body runs, which would make
    /// `self.filesSort = filesSort` a phase-2 assignment — one that DOES fire
    /// `didSet`, racing a re-page against the first load. Left uninitialized, the
    /// compiler requires the init to assign it as direct storage instead.
    public var filesSort: FolderFilesSort {
        didSet {
            guard filesSort != oldValue else { return }
            sortReload = Task { [weak self] in
                await self?.reloadForSort()
            }
        }
    }

    /// The profile the outline is scoped to; every repository read passes it.
    @ObservationIgnored public var activeProfileId: Int64

    @ObservationIgnored let repository: any FolderOutlineReading
    @ObservationIgnored let pageSize: Int
    /// Per-directory state. `@ObservationIgnored` on purpose: ``subtreeRows`` and
    /// ``rootFileRows`` are the observed projection the shell binds to, so a view
    /// never reads this dictionary and can never miss its invalidation.
    @ObservationIgnored var levels: [String: FolderOutlineLevel] = [:]
    @ObservationIgnored var expandedPaths: Set<String> = []
    @ObservationIgnored private var levelLoads: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var orderWrite: Task<Void, Never>?
    @ObservationIgnored private var sortReload: Task<Void, Never>?

    public init(
        repository: any FolderOutlineReading,
        rootPath: String,
        pageSize: Int = 100,
        activeProfileId: Int64 = ProfileRecord.guestID,
        filesSort: FolderFilesSort = .default
    ) {
        self.repository = repository
        self.rootPath = rootPath
        self.pageSize = max(1, pageSize)
        self.activeProfileId = activeProfileId
        self.filesSort = filesSort
    }
}

// MARK: - Loading

public extension FolderOutlineViewModel {
    /// Loads the browsed folder's level, then tops its file window up so a tall
    /// window does not paint one page and stall.
    func load() async {
        isLoading = true
        defer { isLoading = false }
        await loadLevel(rootPath)
        await fillRootViewport()
        rebuildRows()
    }

    /// Whether `path` renders expanded.
    func isExpanded(_ path: String) -> Bool {
        expandedPaths.contains(path)
    }

    /// Expands `path`, loading its level on first open.
    func expand(_ path: String) async {
        guard !expandedPaths.contains(path) else { return }
        expandedPaths.insert(path)
        rebuildRows()
        await loadLevel(path)
        rebuildRows()
    }

    /// Collapses `path`. The loaded level stays cached, so re-expanding it costs no
    /// query — the ``FolderSidebarViewModel`` rule, applied here too.
    func collapse(_ path: String) {
        guard expandedPaths.remove(path) != nil else { return }
        rebuildRows()
    }

    /// Flips `path` between expanded and collapsed.
    func toggle(_ path: String) async {
        if expandedPaths.contains(path) {
            collapse(path)
        } else {
            await expand(path)
        }
    }
}

// MARK: - Per-level pagination

public extension FolderOutlineViewModel {
    /// Whether `levelPath` still has an unfetched page of direct files.
    func hasMoreFiles(in levelPath: String) -> Bool {
        levels[levelPath]?.hasMore ?? false
    }

    /// How many direct files `levelPath` has loaded so far (before the genre chip).
    func loadedFileCount(in levelPath: String) -> Int {
        levels[levelPath]?.files.count ?? 0
    }

    /// Appends one keyset page of direct files to `levelPath`.
    ///
    /// The level's `isLoading` flag is the one-in-flight gate: a burst of `onAppear`
    /// events past the prefetch threshold issues exactly one fetch.
    func loadMoreFiles(in levelPath: String) async {
        guard var level = levels[levelPath], level.hasMore, !level.isLoading else { return }
        let cursor = level.cursor
        level.isLoading = true
        levels[levelPath] = level
        let page = await fetchFiles(in: levelPath, after: cursor)
        var updated = levels[levelPath] ?? FolderOutlineLevel()
        updated.files.append(contentsOf: page.items)
        updated.cursor = page.nextCursor
        updated.hasMore = page.nextCursor != nil
        updated.isLoading = false
        levels[levelPath] = updated
        rebuildRows()
    }

    /// Fetches `file`'s level's next page once the row is within
    /// ``LibraryPagination/prefetchThreshold`` of the end of THAT level's window.
    func prefetchFilesIfNeeded(_ file: FolderOutlineFile) async {
        guard hasMoreFiles(in: file.levelPath),
              LibraryPagination.shouldPrefetch(index: file.indexInLevel, count: file.levelFileCount)
        else { return }
        await loadMoreFiles(in: file.levelPath)
    }
}

// MARK: - Reorder

public extension FolderOutlineViewModel {
    /// Whether a drag may reorder the files at `levelPath`.
    ///
    /// The browsed root ONLY, and only with the genre chip cleared — today's
    /// ``FolderReorderPolicy`` rule, restated for a level. A nested level's page is
    /// title-ordered and its position rows would describe a directory the listener
    /// is only glancing into, so those drags must write nothing.
    ///
    /// A Name or Date-added ``filesSort`` closes the gate for the same reason at the
    /// root: under one of those the row order is the QUERY's, so a drag would
    /// persist positions the next page load discards.
    func canReorder(at levelPath: String) -> Bool {
        levelPath == rootPath && genreFilter.isAll && filesSort == .manual
    }

    /// Applies a drag-reorder to the browsed root's loaded direct files and persists
    /// it as this profile's manual order for that folder.
    ///
    /// Order flows through `folderTrackOrder` exclusively — the frozen `track`
    /// columns are never read or written. Returns the permuted window so the caller
    /// can mirror it into the playback queue, or `nil` when the drag is not allowed.
    @discardableResult
    func moveRootFiles(from source: IndexSet, to destination: Int, isEnabled: Bool) -> [TrackRecord]? {
        guard isEnabled, canReorder(at: rootPath), var level = levels[rootPath] else { return nil }
        var permuted = level.files
        permuted.move(fromOffsets: source, toOffset: destination)
        level.files = permuted
        level.cursor = Self.orderCursor(forLoaded: permuted)
        levels[rootPath] = level
        rebuildRows()
        persistRootOrder(permuted)
        return permuted
    }

    /// Awaits the in-flight folder-order write. A test seam — nothing the app does
    /// depends on the write having landed.
    func awaitPendingOrderWrite() async {
        await orderWrite?.value
    }

    /// Awaits the re-page a ``filesSort`` change scheduled. A test seam — the shell
    /// simply re-renders when the new window lands.
    func awaitPendingSortReload() async {
        await sortReload?.value
    }
}

// MARK: - Internals

extension FolderOutlineViewModel {
    /// Loads one directory's subfolders and first file page, exactly once per level.
    /// Concurrent callers share the in-flight load.
    func loadLevel(_ path: String) async {
        if levels[path]?.isLoaded == true { return }
        if let inFlight = levelLoads[path] {
            await inFlight.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await performLevelLoad(path)
        }
        levelLoads[path] = task
        await task.value
        if levelLoads[path] == task {
            levelLoads[path] = nil
        }
    }

    /// The keyset cursor the loaded window resumes from after a reorder.
    ///
    /// ``persistRootOrder(_:)`` numbers the window `0 ..< count`, so the last row's
    /// key is `orderKey(position: count - 1, …)`. Without re-anchoring, the next page
    /// would resume from the pre-move key and skip or repeat rows.
    static func orderCursor(forLoaded files: [TrackRecord]) -> PageCursor<String>? {
        guard let last = files.last, let lastId = last.id else { return nil }
        return PageCursor(key: orderKey(position: files.count - 1, sortTitle: last.sortTitle), id: lastId)
    }

    /// The composed folder-page sort key, mirroring
    /// `TrackRepository.folderTreeOrderKeySQL` — a fixed-width zero-padded position
    /// concatenated with `COALESCE(sortTitle, '')`. Both sides must format the
    /// position identically or the cursor lands in the wrong place.
    static func orderKey(position: Int, sortTitle: String?) -> String {
        String(format: "%020ld", position) + (sortTitle ?? "")
    }

    private func performLevelLoad(_ path: String) async {
        var level = levels[path] ?? FolderOutlineLevel()
        level.isLoading = true
        levels[path] = level
        let loaded = await fetchLevel(path)
        var updated = levels[path] ?? FolderOutlineLevel()
        updated.subfolders = sortedSubfolders(loaded.children)
        updated.files = loaded.page.items
        updated.cursor = loaded.page.nextCursor
        updated.hasMore = loaded.page.nextCursor != nil
        updated.isLoading = false
        updated.isLoaded = true
        levels[path] = updated
        rebuildRows()
    }

    /// Reads one level off the main actor — the library QoS invariant.
    private func fetchLevel(_ path: String) async -> FolderOutlineLevelFetch {
        let repository = repository
        let profileId = activeProfileId
        let limit = pageSize
        let sort = filesSort
        return await Task.detached {
            let children = (try? repository.childFolders(profileId: profileId, parentPath: path)) ?? []
            let page = (try? repository.tracksDirectlyIn(
                profileId: profileId,
                dirPath: path,
                after: nil,
                limit: limit,
                sort: sort
            )) ?? Page<TrackRecord, String>(items: [], nextCursor: nil)
            return FolderOutlineLevelFetch(children: children, page: page)
        }.value
    }

    func fetchFiles(
        in path: String,
        after cursor: PageCursor<String>?
    ) async -> Page<TrackRecord, String> {
        let repository = repository
        let profileId = activeProfileId
        let limit = pageSize
        let sort = filesSort
        return await Task.detached {
            (try? repository.tracksDirectlyIn(
                profileId: profileId,
                dirPath: path,
                after: cursor,
                limit: limit,
                sort: sort
            )) ?? Page<TrackRecord, String>(items: [], nextCursor: nil)
        }.value
    }

    /// Tops the BROWSED ROOT's file window up to ``LibraryPagination/viewportFillTarget``.
    ///
    /// Bounded twice over (at most ``LibraryPagination/viewportFillMaxPages``, never
    /// past the row target), and applied to the root level only: a nested level opens
    /// below content that is already on screen, so its first page plus the threshold
    /// prefetch is enough, and filling every expanded level would multiply the
    /// resident window by the number of open folders.
    func fillRootViewport() async {
        var fetched = 0
        while fetched < LibraryPagination.viewportFillMaxPages,
              hasMoreFiles(in: rootPath),
              loadedFileCount(in: rootPath) < LibraryPagination.viewportFillTarget
        {
            await loadMoreFiles(in: rootPath)
            fetched += 1
        }
    }

    private func persistRootOrder(_ files: [TrackRecord]) {
        let updates = files.enumerated().compactMap { offset, track -> (trackId: Int64, position: Int)? in
            guard let trackId = track.id else { return nil }
            return (trackId: trackId, position: offset)
        }
        let repository = repository
        let rootPath = rootPath
        let profileId = activeProfileId
        orderWrite = Task {
            try? await repository.updateFolderPositions(profileId: profileId, rootPath: rootPath, updates)
        }
    }
}

/// One level's two reads, returned together so a single `Task.detached` covers both.
private struct FolderOutlineLevelFetch {
    let children: [FolderChildSummary]
    let page: Page<TrackRecord, String>
}
