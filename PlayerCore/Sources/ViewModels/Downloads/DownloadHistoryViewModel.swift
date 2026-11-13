// DownloadHistoryViewModel — the keyset-paginated window over the v17
// `downloadHistory` log that backs the Downloads pane's History tab.
//
// Shaped like ``LyricsBrowserViewModel``: one growing window, `loadInitial()` assigns
// atomically after its fetch resolves (never clearing up front, so a concurrent reload
// cannot wipe the list and then early-return), and `loadMore()` is guarded by
// `isLoading` so a scroll that fires twice appends one page.
//
// ── NO `Task.detached`, AND THAT IS NOT AN OVERSIGHT ─────────────────────────
//
// ``LyricsBrowserViewModel`` wraps its reads in `Task.detached` because `LyricsBrowsing`
// is synchronous and would otherwise block the main thread on a GRDB connection.
// ``DownloadHistoryRepositoryProviding`` is already `async` end to end — every method
// goes through GRDB's own async reader/writer overloads — so a detached hop here would
// add a thread transition around work that has already left the main actor.
//
// ── NOTHING HERE TOUCHES A FILE ──────────────────────────────────────────────
//
// ``remove(id:)`` and ``clearAll()`` delete ROWS. The downloaded files those rows name
// are the listener's, and this type has no `FileManager`, no `URL` write path and no
// way to reach one. The pane says so in its copy; this is where it is true.
//
// ── SEVERAL ROWS CAN NAME THE SAME VIDEO, AND THE SAME FILE ─────────────────
//
// A sequential re-download of a video already on disk is a genuine `.completed`
// outcome (yt-dlp skips the transfer, still prints its `after_move` path and exits 0),
// so history appends a second row sharing one `canonicalVideoID` and one `filePath`.
// Rows are therefore identified by their own `id` — never by video id or path — and
// nothing here deduplicates.
//
// This file imports only Foundation + Observation + Persistence; it MUST NOT import
// AppKit or UIKit (PlayerCore portability invariant), nor URLSession or Process (the
// downloader boundary gate — `PlayerCore/Sources/ViewModels` is scanned wholesale).
import Foundation
import Observation
import Persistence
import Services

/// Pages through download attempts, newest first, and handles retry and removal.
@MainActor
@Observable
public final class DownloadHistoryViewModel {
    /// Accumulated keyset pages, newest first.
    public private(set) var entries: [DownloadHistoryRecord] = []
    /// `true` while a page is being fetched.
    public private(set) var isLoading = false
    /// `false` once the last page has been loaded.
    public private(set) var hasMore = true
    /// Whether ``loadInitial()`` has completed at least once.
    ///
    /// The empty state and the loading state are different screens, and without this
    /// they are indistinguishable on the first frame: an unloaded window and an empty
    /// log both report zero entries. A pane that read only `entries.isEmpty` would
    /// flash "Nothing Downloaded Yet" at every listener with a full history.
    public private(set) var hasLoaded = false

    @ObservationIgnored private let repository: any DownloadHistoryRepositoryProviding
    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private var cursor: PageCursor<Double>?
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var retryingIDs: Set<String> = []

    public init(repository: any DownloadHistoryRepositoryProviding, pageSize: Int = 50) {
        self.repository = repository
        self.pageSize = max(1, pageSize)
    }

    /// Loads (or reloads) the newest page, replacing the window.
    public func loadInitial() async throws {
        loadGeneration &+= 1
        let generation = loadGeneration
        isLoading = true
        defer { finishLoad(generation, marksLoaded: true) }
        let page = try await repository.entries(before: nil, limit: pageSize)
        guard generation == loadGeneration, !Task.isCancelled else { return }
        entries = page.items
        cursor = page.nextCursor
        hasMore = page.nextCursor != nil
    }

    /// Appends the next keyset page, if any.
    public func loadMore() async throws {
        guard hasMore, !isLoading else { return }
        let generation = loadGeneration
        isLoading = true
        defer { finishLoad(generation, marksLoaded: false) }
        let page = try await repository.entries(before: cursor, limit: pageSize)
        guard generation == loadGeneration, !Task.isCancelled else { return }
        entries.append(contentsOf: page.items)
        cursor = page.nextCursor
        hasMore = page.nextCursor != nil
    }

    /// Forgets one entry. The file it names is not touched.
    ///
    /// The row is spliced out of the loaded window rather than reloaded: a reload would
    /// re-fetch only the FIRST page, silently discarding every later page the listener
    /// had already scrolled through.
    ///
    /// `delete`'s `Bool` — whether a row matched — is deliberately ignored. A `false`
    /// means the table held no such id, in which case the splice below removes nothing
    /// either, so guarding on it would be a branch no input can reach (a real failure
    /// throws instead of answering `false`). Mutation-proven: a guard here stayed green
    /// against every test that could be written for it.
    public func remove(id: String) async throws {
        try await repository.delete(id: id)
        entries.removeAll { $0.id == id }
        if isLoading {
            try await loadInitial()
        }
    }

    /// Queues the failed video as a single. The attempt leaves History only after
    /// the queue accepts a new item. An existing queued copy can still be shown.
    public func retry(_ entry: DownloadHistoryRecord, using downloads: DownloadsViewModel) async throws -> Bool {
        guard entry.failureReason != nil,
              let url = YouTubeURLNormalizer.canonicalURL(forVideoID: entry.canonicalVideoID),
              entries.contains(where: { $0.id == entry.id }),
              retryingIDs.insert(entry.id).inserted
        else { return false }
        defer { retryingIDs.remove(entry.id) }

        let report = await downloads.enqueue(urls: [url])
        if report.added > 0 {
            try await remove(id: entry.id)
            return true
        }
        return report.duplicatesDropped > 0
    }

    /// Forgets every entry. No file is touched.
    ///
    /// The cursor is reset with the window because the log it anchored into is gone;
    /// leaving it would make the next ``loadMore()`` ask for rows after a row that no
    /// longer exists.
    public func clearAll() async throws {
        _ = try await repository.deleteAll()
        loadGeneration &+= 1
        isLoading = false
        entries = []
        cursor = nil
        hasMore = false
    }

    private func finishLoad(_ generation: Int, marksLoaded: Bool) {
        guard generation == loadGeneration else { return }
        isLoading = false
        if marksLoaded { hasLoaded = true }
    }

    /// Whether the window should grow once `index` has been rendered.
    ///
    /// A named decision rather than an inline comparison in the view, so "paginate on
    /// the last loaded row" is stated once and is assertable without a hosted list.
    public func shouldPaginate(at index: Int) -> Bool {
        hasMore && index == entries.count - 1
    }
}
