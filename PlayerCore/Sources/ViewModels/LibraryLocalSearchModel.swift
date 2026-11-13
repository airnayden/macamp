// LibraryLocalSearchModel — the library browser's in-view filter field, backed by
// the database instead of the loaded window.
//
// The field used to narrow only the rows already paged into memory, so a match
// living past the loaded window was invisible — and the All Tracks list had no
// in-view filtering at all. This model turns that field into a real query: a
// non-empty term debounces for 250 ms and then hits FTS5, library-wide for All
// Tracks and narrowed to the folder subtree when the browser is scoped to a
// library root.
//
// It mirrors ``SearchViewModel`` deliberately — same debounce, same growing
// result window, same off-main read — because this *is* the global search
// field's behaviour applied to a second surface.
//
// SEMANTICS CHANGE (intentional): FTS5 matches token PREFIXES on
// title/artist/album ("boh rha" becomes the pattern `boh* rha*`), while the
// in-memory `matchesFilter` this replaces in folder views matched any
// SUBSTRING. A mid-word fragment such as "ohem" therefore stops matching in a
// folder view. That is accepted: it makes the in-view field behave exactly like
// the global search field, and All Tracks gains search where it previously had
// none, so there is nothing to regress there. `matchesFilter` itself is
// untouched — Favourites and the playlist detail still use it.
//
// Foundation + Observation + Persistence only. No networking of any kind lives
// in this module (the AI network-boundary guard forbids `URLSession` under
// `PlayerCore/Sources/ViewModels`), and no AppKit/UIKit (portability guard).
import Foundation
import Observation
import Persistence

// MARK: - Read seam

/// The narrow, profile-scoped full-text seam the in-view search field needs: the
/// library-wide ranked search and its folder-scoped counterpart.
///
/// The production conformer is ``TrackRepository``; tests inject a fake that
/// records which overload ran with which arguments. Deliberately NOT a
/// `TrackRepositoryProviding` requirement — mirroring ``FolderTreeReading``, only
/// this view model needs the folder-scoped overload, and that overload stays a
/// concrete `TrackRepository` extension (Task 2's shipped API is unchanged).
public protocol LibraryLocalSearchReading: Sendable {
    /// Ranked full-text search across every track visible to `profileId`.
    func searchTracks(profileId: Int64, query: String, limit: Int) throws -> [TrackRecord]
    /// Ranked full-text search narrowed to the subtree beneath `rootPath`.
    func searchTracks(profileId: Int64, rootPath: String, query: String, limit: Int) throws -> [TrackRecord]
}

extension TrackRepository: LibraryLocalSearchReading {}

// MARK: - Scope

/// Which corpus the in-view search field queries.
public enum LibraryLocalSearchScope: Sendable, Equatable, Hashable {
    /// Every track visible to the profile — the All Tracks browser.
    case allTracks
    /// Only the tracks beneath one library root — a folder browser.
    case folder(rootPath: String)
}

// MARK: - Model

/// Debounced, windowed full-text search for the library browser's filter field.
///
/// Results are "paginated" by growing the window (``loadMore()`` widens the
/// `LIMIT`) rather than by a keyset cursor: FTS5 relevance ranking has no stable
/// cursor, exactly as ``SearchViewModel`` documents.
///
/// The model owns *only* the search corpus. The browser's keyset browse window is
/// never touched, so clearing the query restores the paged list without refetching
/// a single page.
@MainActor
@Observable
public final class LibraryLocalSearchModel {
    /// The first window's size, and the increment each ``loadMore()`` adds.
    public static let defaultPageSize = 50

    /// The latest text the field submitted.
    public private(set) var query = ""
    /// Ranked results (best match first), capped at the current window.
    public private(set) var results: [TrackRecord] = []
    /// `true` while a (debounced) search is in flight.
    public private(set) var isSearching = false
    /// `true` when the last window came back full, so a wider `LIMIT` may reveal
    /// more rows. Ranked search has no "last page" marker beyond this.
    public private(set) var hasMore = false

    /// Whether the browser should render search results instead of browse rows.
    public var isActive: Bool {
        !trimmedQuery.isEmpty
    }

    /// The corpus being searched. Re-pointed by ``configure(reader:scope:activeProfileId:)``.
    @ObservationIgnored public private(set) var scope: LibraryLocalSearchScope
    /// The profile whose visible tracks the search is scoped to.
    @ObservationIgnored public private(set) var activeProfileId: Int64

    @ObservationIgnored private var reader: (any LibraryLocalSearchReading)?
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private var currentLimit: Int
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    /// Creates a search model.
    ///
    /// - Parameters:
    ///   - reader: The FTS5-backed repository. `nil` until the shell can build one
    ///     from its environment — a search issued before then is simply inert.
    ///   - scope: The corpus to query.
    ///   - debounce: Delay before a query reaches FTS5 (tests pass a short value).
    ///   - pageSize: Result-window growth increment.
    ///   - activeProfileId: The profile to scope reads to (Guest by default).
    public init(
        reader: (any LibraryLocalSearchReading)? = nil,
        scope: LibraryLocalSearchScope = .allTracks,
        debounce: Duration = .milliseconds(250),
        pageSize: Int = defaultPageSize,
        activeProfileId: Int64 = ProfileRecord.guestID
    ) {
        self.reader = reader
        self.scope = scope
        self.debounce = debounce
        self.pageSize = max(1, pageSize)
        currentLimit = max(1, pageSize)
        self.activeProfileId = activeProfileId
    }

    deinit {
        searchTask?.cancel()
    }

    /// Points the model at a repository, corpus and profile.
    ///
    /// The shell calls this on every load, because the browsed folder and the
    /// active profile both change under it. A change to either while a query is
    /// live re-runs that query against the new corpus immediately (no debounce —
    /// the user already waited once for this text).
    public func configure(
        reader: any LibraryLocalSearchReading,
        scope: LibraryLocalSearchScope,
        activeProfileId: Int64
    ) {
        let corpusChanged = self.scope != scope || self.activeProfileId != activeProfileId
        self.reader = reader
        self.scope = scope
        self.activeProfileId = activeProfileId
        guard corpusChanged, isActive else { return }
        currentLimit = pageSize
        scheduleSearch(debounced: false)
    }

    /// Submits field text. Successive keystrokes coalesce to the final query.
    public func search(_ text: String) {
        query = text
        currentLimit = pageSize
        scheduleSearch(debounced: true)
    }

    /// Grows the result window by one page.
    ///
    /// `async` (unlike ``SearchViewModel/loadMore()``) because the browser's
    /// pagination path awaits each page before deciding whether to fetch another.
    public func loadMore() async {
        guard hasMore, !isSearching, !trimmedQuery.isEmpty else { return }
        currentLimit += pageSize
        await runSearch()
    }

    /// Cancels any pending search and clears the query and results.
    public func clear() {
        searchTask?.cancel()
        query = ""
        results = []
        hasMore = false
        isSearching = false
        currentLimit = pageSize
    }
}

private extension LibraryLocalSearchModel {
    var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func scheduleSearch(debounced: Bool) {
        searchTask?.cancel()
        guard !trimmedQuery.isEmpty else {
            results = []
            hasMore = false
            isSearching = false
            return
        }
        let wait = debounced ? debounce : .zero
        searchTask = Task { [weak self] in
            if wait > .zero {
                try? await Task.sleep(for: wait)
            }
            if Task.isCancelled { return }
            await self?.runSearch()
        }
    }

    /// Runs the ranked read off the main actor and publishes it.
    func runSearch() async {
        guard let reader else { return }
        isSearching = true
        let limit = currentLimit
        let found = await Self.fetch(
            reader,
            scope: scope,
            profileId: activeProfileId,
            text: trimmedQuery,
            limit: limit
        )
        isSearching = false
        if Task.isCancelled { return }
        results = found
        hasMore = found.count >= limit
    }

    /// Performs the synchronous FTS5 read off the main actor (the reader is
    /// `Sendable`), routing to the folder-scoped overload when a root is browsed.
    static func fetch(
        _ reader: any LibraryLocalSearchReading,
        scope: LibraryLocalSearchScope,
        profileId: Int64,
        text: String,
        limit: Int
    ) async -> [TrackRecord] {
        await Task.detached {
            switch scope {
            case .allTracks:
                (try? reader.searchTracks(profileId: profileId, query: text, limit: limit)) ?? []
            case let .folder(rootPath):
                (try? reader.searchTracks(
                    profileId: profileId,
                    rootPath: rootPath,
                    query: text,
                    limit: limit
                )) ?? []
            }
        }.value
    }
}
