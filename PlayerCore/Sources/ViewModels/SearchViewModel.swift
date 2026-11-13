// SearchViewModel — debounced FTS5 track search for the library search UI.
//
// Rapid keystrokes coalesce: each ``search(_:)`` cancels the pending task, so
// only the final query (after the debounce interval) hits FTS5. Ranked results
// are "paginated" by growing the result window (`loadMore()` increases the
// LIMIT) — FTS5 ranking has no stable keyset cursor.
//
// The (synchronous) repository read runs on a detached task, never on the main
// actor, so a cold 100k-row search never blocks the UI (PlayerCore "don't block
// on @MainActor" rule).
//
// This file imports only Foundation + Observation + Persistence; it MUST NOT
// import AppKit or UIKit (PlayerCore portability invariant).
import Foundation
import Observation
import Persistence

/// Debounced, windowed full-text search over the `track` FTS5 index.
@MainActor
@Observable
public final class SearchViewModel {
    /// The latest query text the UI submitted.
    public private(set) var query = ""
    /// Ranked search results (best match first), capped at the current window.
    public private(set) var results: [TrackRecord] = []
    /// `true` while a (debounced) search is in flight.
    public private(set) var isSearching = false

    @ObservationIgnored private let repository: any TrackRepositoryProviding
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private var currentLimit: Int
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    /// The profile whose search this view model is scoped to (Guest `1` by
    /// default). Set at construction from the active profile and re-assigned by the
    /// profile-switch seam (Task 11); scoped repository reads pass it (Task 7).
    @ObservationIgnored public var activeProfileId: Int64

    /// Creates a search view model.
    ///
    /// - Parameters:
    ///   - repository: The FTS5-backed track repository.
    ///   - debounce: Delay before a query reaches FTS5 (tests pass `.zero`).
    ///   - pageSize: Result-window growth increment.
    ///   - activeProfileId: The profile to scope reads to (Guest `1` by default).
    public init(
        repository: any TrackRepositoryProviding,
        debounce: Duration = .milliseconds(250),
        pageSize: Int = 50,
        activeProfileId: Int64 = 1
    ) {
        self.repository = repository
        self.debounce = debounce
        self.pageSize = max(1, pageSize)
        currentLimit = max(1, pageSize)
        self.activeProfileId = activeProfileId
    }

    deinit {
        searchTask?.cancel()
    }

    /// Debounced full-text search. Successive calls coalesce to the final query.
    public func search(_ text: String) {
        query = text
        currentLimit = pageSize
        scheduleSearch(debounced: true)
    }

    /// Grows the result window for the current query (ranked pagination).
    public func loadMore() {
        guard !trimmedQuery.isEmpty, !isSearching else { return }
        currentLimit += pageSize
        scheduleSearch(debounced: false)
    }

    /// Cancels any pending search and clears the query + results.
    public func clear() {
        searchTask?.cancel()
        query = ""
        results = []
        isSearching = false
        currentLimit = pageSize
    }
}

private extension SearchViewModel {
    var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func scheduleSearch(debounced: Bool) {
        searchTask?.cancel()
        let text = trimmedQuery
        guard !text.isEmpty else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        let repo = repository
        let limit = currentLimit
        let profileId = activeProfileId
        let wait = debounced ? debounce : .zero
        searchTask = Task { [weak self] in
            if wait > .zero {
                try? await Task.sleep(for: wait)
            }
            if Task.isCancelled { return }
            let found = await Self.runSearch(repo, profileId: profileId, text: text, limit: limit)
            if Task.isCancelled { return }
            self?.apply(found)
        }
    }

    /// Runs the synchronous FTS5 read off the main actor (the repository is `Sendable`).
    static func runSearch(
        _ repository: any TrackRepositoryProviding,
        profileId: Int64,
        text: String,
        limit: Int
    ) async -> [TrackRecord] {
        await Task.detached {
            (try? repository.searchTracks(profileId: profileId, query: text, limit: limit)) ?? []
        }.value
    }

    func apply(_ found: [TrackRecord]) {
        results = found
        isSearching = false
    }
}
