// LibraryBrowserRows — the cached row pipeline behind ``LibraryBrowserView``.
//
// The browser used to derive its rows inside `body`: `displayedTracks` → the genre
// chip → `map(LibraryTrackRow.init)` → `sorted(using:)`. That whole chain re-ran on
// EVERY SwiftUI body evaluation, and the sort re-ran again on every `onAppear`
// prefetch probe (`loadMoreIfNeeded` re-derived the sorted window), so scrolling
// window re-allocated and re-sorted the entire list many times per frame.
//
// It now runs ONCE per change into `derivedRows` + `rowIndexById` — the
// ``FolderOutlineViewModel/rebuildRows()`` pattern — and every render-time reader
// consumes the cached arrays instead.
//
// The in-memory sort is KEPT; it is NOT redundant with the database order. A genre
// window arrives `track.id`-ordered, local-search results arrive BM25-ranked, and
// the comparator's key (``LibraryTrackRow/titleText``, i.e. `TrackRecord.displayTitle`)
// is not the keyset key (`sortTitle`). Dropping it would visibly reorder every list.
//
// A separate file from `LibraryBrowserView.swift` / `LibraryBrowserActions.swift`
// purely to keep all three sources inside the SwiftLint file-length budget — the
// `LibraryBrowserPagination.swift` precedent. Members are internal because the
// sibling view files invoke them.
import Persistence
import SwiftUI
import ViewModels

/// The pure derivation behind ``LibraryBrowserView``'s row cache.
///
/// A caseless enum so the whole pipeline is reachable from `macampMacTests` without
/// standing up a view — the ``FolderReorderPolicy`` precedent.
enum LibraryBrowserRows {
    /// Derives the rows the browser renders, plus an O(1) row-id → position index.
    ///
    /// One pass, reproducing exactly what the previous computed chain produced:
    ///
    /// 1. `displayedTracks` — ranked search results while the in-view field holds a
    ///    term, the paged browse window otherwise.
    /// 2. the genre chip, applied **client-side to search results only**. A browse
    ///    window is already narrowed upstream by
    ///    ``LibraryBrowserView/syncSourceTracks()``; re-applying it here would narrow
    ///    a *stale* window in the frame between a chip tap and its reload landing.
    /// 3. the ``LibraryTrackRow`` projection.
    /// 4. `sorted(using: sortOrder)`, gated by
    ///    ``FolderReorderPolicy/appliesTableSort(filterRootPath:)`` so a folder's
    ///    user-owned drag order is never re-sorted.
    ///
    /// `indexById` keeps the FIRST position of each id, matching the
    /// `firstIndex(where:)` scan it replaces — ids collide only for rows whose
    /// `TrackRecord.id` is nil, where ``LibraryTrackRow/id`` falls back to `0`.
    ///
    /// `filterRootPath` defaults to `nil` (All Tracks, where the sort applies).
    static func deriveRows(
        source: [TrackRecord],
        searchActive: Bool,
        searchResults: [TrackRecord],
        genre: GenreFilter,
        filterRootPath: String? = nil,
        sortOrder: [KeyPathComparator<LibraryTrackRow>]
    ) -> (rows: [LibraryTrackRow], indexById: [Int64: Int]) {
        let tracks = searchActive ? searchResults.filter { matches(genre, $0) } : source
        let projected = tracks.map { LibraryTrackRow(track: $0) }
        let rows = FolderReorderPolicy.appliesTableSort(filterRootPath: filterRootPath)
            ? projected.sorted(using: sortOrder)
            : projected
        var indexById: [Int64: Int] = [:]
        indexById.reserveCapacity(rows.count)
        for (index, row) in rows.enumerated() where indexById[row.id] == nil {
            indexById[row.id] = index
        }
        return (rows, indexById)
    }

    /// The genre chip's predicate — the same three cases
    /// ``LibraryBrowserView/applyingGenreFilter(_:)`` applies, kept verbatim so the
    /// derived order stays byte-identical to the chain it replaces.
    private static func matches(_ genre: GenreFilter, _ track: TrackRecord) -> Bool {
        switch genre {
        case .all: true
        case .untagged: track.genre == nil || (track.genre ?? "").isEmpty
        case let .genre(name): track.genre == name
        }
    }
}

// MARK: - Rebuild

extension LibraryBrowserView {
    /// Recomputes ``derivedRows`` / ``rowIndexById`` from the current window.
    ///
    /// Every path that can change the rendered list calls this exactly once:
    /// ``syncSourceTracks()`` (initial load, reload, next page, folder drag), the
    /// genre chip, BOTH halves of the search model's state (`isActive` and `results`
    /// — entering search and a later debounced query landing are separate events),
    /// and the sort order. `loadKey` (profile or folder change) and
    /// `environment.libraryFolders.revision` route through `reloadTracks()` into
    /// `syncSourceTracks()` and so need no wiring of their own — note the revision
    /// now also fires seconds after launch, mid-scroll, when the background
    /// catch-up scan commits, which this rebuild absorbs like any other reload.
    ///
    /// Nothing that varies per RENDER may be read here: favourite overrides,
    /// availability badges, karaoke row state, the now-playing highlight and the
    /// selection are all resolved at render time from `row.track`, never baked into
    /// a row — ``LibraryTrackRow`` carries only the record and its display strings.
    func rebuildDerivedRows() {
        let derived = LibraryBrowserRows.deriveRows(
            source: sourceTracks,
            searchActive: localSearch.isActive,
            searchResults: localSearch.results,
            genre: selectedGenre,
            filterRootPath: filterRootPath,
            sortOrder: sortOrder
        )
        derivedRows = derived.rows
        rowIndexById = derived.indexById
    }
}
