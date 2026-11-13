// GenreBrowserViewModel — the keyset-paginated track window for ONE genre
// selection (Task 14). When the library genre filter is a specific genre or the
// "(no genre)" bucket, the macOS `LibraryBrowserView` and the iOS `LibraryScreen`
// drive this instead of the shared all-tracks `LibraryViewModel`, paging
// `TrackRepository.tracksByGenre` (id keyset) so a large genre never loads at
// once. Reads run OFF the main actor (`Task.detached`) so the main thread never
// blocks on a GRDB reader (the library QoS invariant). One instance per
// selection — rebuilt when the chosen genre changes.
import Foundation
import Observation
import Persistence

/// Paginates the tracks of a single genre selection, mirroring
/// ``FolderBrowserViewModel`` but filtered by `tracksByGenre` rather than path.
@MainActor
@Observable
public final class GenreBrowserViewModel {
    /// Accumulated keyset pages of this genre's tracks, ordered by `id`.
    public private(set) var tracks: [TrackRecord] = []
    /// `true` while a page is being fetched.
    public private(set) var isLoading = false
    /// `false` once the last page has been loaded.
    public private(set) var hasMore = true

    @ObservationIgnored private let repository: any TrackRepositoryProviding
    @ObservationIgnored private let genre: String?
    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private var cursor: PageCursor<Int64>?

    /// The profile whose genre window this view model is scoped to (Guest `1` by
    /// default). Set at construction from the active profile and re-assigned by the
    /// profile-switch seam (Task 11); scoped repository reads pass it (Task 7).
    @ObservationIgnored public var activeProfileId: Int64

    public init(
        repository: any TrackRepositoryProviding,
        genre: String?,
        pageSize: Int = 100,
        activeProfileId: Int64 = 1
    ) {
        self.repository = repository
        self.genre = genre
        self.pageSize = max(1, pageSize)
        self.activeProfileId = activeProfileId
    }

    /// Loads (or reloads) the first keyset page for this genre.
    ///
    /// Assigns `tracks` atomically after the fetch resolves: it must not clear
    /// `tracks` up front nor route through the `isLoading`-guarded ``loadMore()``.
    /// Doing so let a concurrent caller wipe `tracks` and then early-return on the
    /// guard, leaving the genre window empty on first paint. Mirrors
    /// ``LibraryViewModel/loadInitialTracks()``.
    public func loadInitial() async throws {
        isLoading = true
        defer { isLoading = false }
        let page = try await fetchPage(after: nil)
        tracks = page.items
        cursor = page.nextCursor
        hasMore = page.nextCursor != nil
    }

    /// Appends the next keyset page for this genre, if any.
    public func loadMore() async throws {
        guard hasMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let page = try await fetchPage(after: cursor)
        tracks.append(contentsOf: page.items)
        cursor = page.nextCursor
        hasMore = page.nextCursor != nil
    }

    private func fetchPage(after cursor: PageCursor<Int64>?) async throws -> Page<TrackRecord, Int64> {
        let repository = repository
        let genre = genre
        let pageSize = pageSize
        let profileId = activeProfileId
        return try await Task.detached {
            try repository.tracksByGenre(profileId: profileId, genre: genre, after: cursor, limit: pageSize)
        }.value
    }
}
