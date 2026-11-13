// KaraokeReadyListViewModel — the keyset-paginated window over the karaoke-ready
// tracks for the active profile. When the sidebar selection is `.fixed(.karaoke)`
// the macOS `KaraokeReadyListView` drives this, paging the set of source paths a
// `KaraokeReadyStore` reports ready through `TrackRepository.tracksByPaths`
// (`(sortTitle, id)` keyset) so a huge ready set never loads at once. Reads run
// OFF the main actor (`Task.detached`) so the main thread never blocks on a GRDB
// reader. The view re-invokes `loadInitial(paths:)` on ready-set (`version`) and
// profile changes; this VM owns only the paging window. Mirrors
// ``FolderBrowserViewModel``.
import Foundation
import GRDB
import Observation
import Persistence

/// A narrow read seam for paging the profile-scoped karaoke-ready tracks. The
/// production conformer is ``TrackRepository`` (wrapping its concrete
/// `tracksByPaths`); tests inject a fake. Deliberately NOT a
/// `TrackRepositoryProviding` requirement (Task 5 keeps `tracksByPaths`
/// concrete-only) — only this view model needs the seam.
public protocol KaraokeReadyPaging: Sendable {
    func readyTracks(
        profileId: Int64,
        paths: [String],
        after cursor: PageCursor<String>?,
        limit: Int
    ) throws -> [ProfileScopedTrack]
}

extension TrackRepository: KaraokeReadyPaging {
    public func readyTracks(
        profileId: Int64,
        paths: [String],
        after cursor: PageCursor<String>?,
        limit: Int
    ) throws -> [ProfileScopedTrack] {
        try tracksByPaths(profileId: profileId, paths: paths, after: cursor, limit: limit)
    }
}

/// Paginates the karaoke-ready tracks for the active profile, mirroring
/// ``FolderBrowserViewModel``'s track window but filtered to a caller-supplied set
/// of ready source paths via ``KaraokeReadyPaging``.
@MainActor
@Observable
public final class KaraokeReadyListViewModel {
    /// Accumulated keyset pages of ready tracks, ordered by `(sortTitle, id)`.
    public private(set) var tracks: [ProfileScopedTrack] = []
    /// `true` while a page is being fetched.
    public private(set) var isLoading = false
    /// `false` once the last page has been loaded.
    public private(set) var hasMore = true

    /// The user's filter text. An empty or whitespace-only query shows every loaded
    /// row; otherwise ``filteredRows`` keeps only rows whose title or artist contains
    /// it. Assigning it re-derives ``filteredRows`` (equality-guarded), so binding a
    /// search field straight to it is enough.
    public var searchQuery: String = "" {
        didSet { applyFilter() }
    }

    /// ``tracks`` filtered by ``searchQuery`` — the surface the list binds to. Equals
    /// ``tracks`` when the query is empty. A pure projection of the loaded window: it
    /// never triggers a fetch and re-derives after every ``loadInitial(paths:)`` /
    /// ``loadMore()``, so the filter survives paging and profile switches without
    /// touching the keyset queries.
    public private(set) var filteredRows: [ProfileScopedTrack] = []

    @ObservationIgnored private let repository: any KaraokeReadyPaging
    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private var cursor: PageCursor<String>?
    @ObservationIgnored private var paths: [String] = []

    /// The profile this window is scoped to (Guest by default). Re-assigned by the
    /// view on a profile switch before it calls ``loadInitial(paths:)`` again.
    @ObservationIgnored public var activeProfileId: Int64

    public init(
        repository: any KaraokeReadyPaging,
        pageSize: Int = 100,
        activeProfileId: Int64 = ProfileRecord.guestID
    ) {
        self.repository = repository
        self.pageSize = max(1, pageSize)
        self.activeProfileId = activeProfileId
    }

    /// Loads (or reloads) the first keyset page for `paths`.
    ///
    /// Assigns `tracks` atomically after the fetch resolves — it must not clear
    /// `tracks` up front nor route through the `isLoading`-guarded ``loadMore()``,
    /// which would let a concurrent reload wipe the window and then early-return.
    /// Mirrors ``FolderBrowserViewModel/loadInitial()``.
    public func loadInitial(paths: [String]) async throws {
        self.paths = paths
        isLoading = true
        defer { isLoading = false }
        let page = try await fetchPage(after: nil)
        tracks = page
        cursor = Self.nextCursor(after: page, pageSize: pageSize)
        hasMore = cursor != nil
        applyFilter()
    }

    /// Appends the next keyset page, if any.
    public func loadMore() async throws {
        guard hasMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let page = try await fetchPage(after: cursor)
        tracks.append(contentsOf: page)
        cursor = Self.nextCursor(after: page, pageSize: pageSize)
        hasMore = cursor != nil
        applyFilter()
    }

    /// Re-derives ``filteredRows`` from the loaded ``tracks`` window and the current
    /// ``searchQuery``. A whitespace-only query keeps every row; otherwise a row
    /// survives when its title OR artist contains the query using the case- and
    /// diacritic-insensitive, locale-aware `localizedStandardContains` (the same
    /// comparison Finder search uses, so "beyonce" matches "Beyoncé"). Equality-guarded
    /// per SKILL macOS UI perf rule 3: an unchanged result is not re-assigned, so a
    /// query edit that leaves the visible rows identical never re-renders the list.
    private func applyFilter() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let next: [ProfileScopedTrack] = if query.isEmpty {
            tracks
        } else {
            tracks.filter { row in
                (row.track.title ?? "").localizedStandardContains(query)
                    || (row.track.artistName ?? "").localizedStandardContains(query)
            }
        }
        guard next != filteredRows else { return }
        filteredRows = next
    }

    private func fetchPage(after cursor: PageCursor<String>?) async throws -> [ProfileScopedTrack] {
        let repository = repository
        let paths = paths
        let pageSize = pageSize
        let profileId = activeProfileId
        return try await Task.detached {
            try repository.readyTracks(profileId: profileId, paths: paths, after: cursor, limit: pageSize)
        }.value
    }

    /// The cursor resuming after the last row, or `nil` at the end. `tracksByPaths`
    /// returns no cursor of its own (Task 5), so a full page (`count == pageSize`)
    /// resumes from the last row's `(sortTitle, id)` and a short/empty page ends.
    private static func nextCursor(
        after page: [ProfileScopedTrack],
        pageSize: Int
    ) -> PageCursor<String>? {
        guard page.count >= pageSize, let last = page.last else { return nil }
        return PageCursor(key: last.track.sortTitle ?? "", id: last.track.id ?? 0)
    }
}
