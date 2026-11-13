// FolderBrowserViewModel — the keyset-paginated track window for ONE library-root
// folder (Task 13). When the sidebar selection is `.folder(rootId:)`, the macOS
// `LibraryBrowserView` drives this instead of the shared all-tracks
// `LibraryViewModel`, paging `TrackRepository.tracksByRoot` (id keyset) so a huge
// folder never loads at once. Reads run OFF the main actor (`Task.detached`) so
// the main thread never blocks on a GRDB reader (the library QoS invariant). One
// instance per selected root — rebuilt on selection change.
import Foundation
import Observation
import Persistence

/// Paginates the tracks beneath a single library-root folder, mirroring
/// ``LibraryViewModel``'s track window but filtered to one root via `tracksByRoot`.
@MainActor
@Observable
public final class FolderBrowserViewModel {
    /// Accumulated keyset pages of this folder's tracks, ordered by `id`.
    public private(set) var tracks: [TrackRecord] = []
    /// `true` while a page is being fetched.
    public private(set) var isLoading = false
    /// `false` once the last page has been loaded.
    public private(set) var hasMore = true

    @ObservationIgnored private let repository: any TrackRepositoryProviding
    @ObservationIgnored private let rootPath: String
    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private var cursor: PageCursor<Int64>?
    @ObservationIgnored private var orderWrite: Task<Void, Never>?

    /// The profile whose folder this view model is scoped to (Guest `1` by
    /// default). Set at construction from the active profile and re-assigned by the
    /// profile-switch seam (Task 11); scoped repository reads pass it (Task 7).
    @ObservationIgnored public var activeProfileId: Int64

    public init(
        repository: any TrackRepositoryProviding,
        rootPath: String,
        pageSize: Int = 100,
        activeProfileId: Int64 = 1
    ) {
        self.repository = repository
        self.rootPath = rootPath
        self.pageSize = max(1, pageSize)
        self.activeProfileId = activeProfileId
    }

    /// Loads (or reloads) the first keyset page for this folder.
    ///
    /// Assigns `tracks` atomically after the fetch resolves: it must not clear
    /// `tracks` up front nor route through the `isLoading`-guarded ``loadMore()``.
    /// Doing so let a concurrent caller wipe `tracks` and then early-return on the
    /// guard, leaving the folder window empty on first paint. Mirrors
    /// ``LibraryViewModel/loadInitialTracks()``.
    public func loadInitial() async throws {
        isLoading = true
        defer { isLoading = false }
        let page = try await fetchPage(after: nil)
        tracks = page.items
        cursor = page.nextCursor
        hasMore = page.nextCursor != nil
    }

    /// Appends the next keyset page for this folder, if any.
    public func loadMore() async throws {
        guard hasMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let page = try await fetchPage(after: cursor)
        tracks.append(contentsOf: page.items)
        cursor = page.nextCursor
        hasMore = page.nextCursor != nil
    }

    /// Applies a drag-reorder to the loaded window and persists it as this profile's
    /// manual order for this root.
    ///
    /// Returns the permuted window so the caller can mirror it into the playback
    /// queue, or `nil` when `isEnabled` is `false` — the browser passes
    /// ``FolderReorderPolicy/allowsReorder(filterRootPath:isGenreFilterAll:)``, so an
    /// All-Tracks or genre-filtered drag writes nothing at all.
    ///
    /// The permutation is synchronous so the list redraws on the same frame as the
    /// drop; only the database write is deferred.
    @discardableResult
    public func moveTracks(from source: IndexSet, to destination: Int, isEnabled: Bool) -> [TrackRecord]? {
        guard isEnabled else { return nil }
        var permuted = tracks
        permuted.move(fromOffsets: source, toOffset: destination)
        tracks = permuted
        resetCursorForLoadedOrder()
        persistLoadedOrder()
        return permuted
    }

    /// Reorders the loaded window to match `orderedIds`, the render-chain half of a
    /// drag: the browser draws from a snapshot of ``tracks``, so a move that never
    /// lands here is invisible however correctly it was persisted.
    ///
    /// Ids the window does not hold are ignored; loaded tracks the caller omitted
    /// keep their relative order at the end.
    public func applyLocalOrder(_ orderedIds: [Int64]) {
        var remaining: [Int64: TrackRecord] = [:]
        for track in tracks where track.id != nil {
            remaining[track.id ?? 0] = track
        }
        var reordered = orderedIds.compactMap { remaining.removeValue(forKey: $0) }
        reordered.append(contentsOf: tracks.filter { remaining[$0.id ?? 0] != nil })
        tracks = reordered
        resetCursorForLoadedOrder()
    }

    /// Awaits the in-flight folder-order write. A test seam: the app never needs it,
    /// because nothing it does depends on the write having landed.
    public func awaitPendingOrderWrite() async {
        await orderWrite?.value
    }

    /// Re-anchors the keyset cursor on the last loaded row's NEW key.
    ///
    /// ``persistLoadedOrder()`` numbers the loaded window `0 ..< count`, so the last
    /// row's order key is `count - 1`. Without this, `loadMore()` would resume from
    /// the pre-move key and skip or repeat rows.
    private func resetCursorForLoadedOrder() {
        guard let lastId = tracks.last?.id else {
            cursor = nil
            return
        }
        cursor = PageCursor(key: Int64(tracks.count - 1), id: lastId)
    }

    private func persistLoadedOrder() {
        let updates = tracks.enumerated().compactMap { offset, track -> (trackId: Int64, position: Int)? in
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

    private func fetchPage(after cursor: PageCursor<Int64>?) async throws -> Page<TrackRecord, Int64> {
        let repository = repository
        let rootPath = rootPath
        let pageSize = pageSize
        let profileId = activeProfileId
        return try await Task.detached {
            try repository.tracksByRoot(profileId: profileId, rootPath: rootPath, after: cursor, limit: pageSize)
        }.value
    }
}
