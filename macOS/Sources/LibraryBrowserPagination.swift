// LibraryBrowserPagination — page fetching for ``LibraryBrowserView``.
//
// Three pieces, all bounded: a threshold prefetch (a row within
// `LibraryPagination.prefetchThreshold` of the end schedules the next page, so the
// fetch lands before the reader hits the bottom), the one-in-flight gate that
// collapses a burst of `onAppear` events into a single fetch, and a capped
// viewport fill that tops a freshly loaded window up so a tall window does not
// start half empty. Page size is untouched; only *when* a page is asked for moved.
//
// A separate file from `LibraryBrowserActions.swift` purely to keep both sources
// under the SwiftLint file-length limit — the `LibraryScanner+Chunk.swift`
// precedent. Members are internal because the sibling view file invokes them.
import SwiftUI
import ViewModels

// MARK: - Loaded-window state

extension LibraryBrowserView {
    /// Whether the active track window still has an unfetched page behind it.
    ///
    /// Search is the fourth window and must be tested first: while the in-view
    /// field holds a term the list renders ranked results, so the browse window's
    /// own `hasMore` says nothing about whether *this* list can grow.
    var hasMoreTracks: Bool {
        if localSearch.isActive {
            localSearch.hasMore
        } else if filterRootPath != nil {
            folderModel?.hasMore ?? false
        } else if let genreModel {
            genreModel.hasMore
        } else {
            environment.library.hasMoreTracks
        }
    }

    /// How many rows the active track window has loaded so far.
    var loadedTrackCount: Int {
        if localSearch.isActive {
            localSearch.results.count
        } else if filterRootPath != nil {
            folderModel?.tracks.count ?? 0
        } else if let genreModel {
            genreModel.tracks.count
        } else {
            environment.library.tracks.count
        }
    }
}

// MARK: - Threshold prefetch + bounded viewport fill

extension LibraryBrowserView {
    /// Fetches the next page once `row` is within
    /// ``LibraryPagination/prefetchThreshold`` rows of the end of the loaded window.
    ///
    /// The cheap checks run first: with nothing left to load, or a fetch already in
    /// flight, the row's index is never looked up. Scrolling past the threshold
    /// makes every trailing row appear at once, so the gate — not the row identity
    /// — is what keeps that burst down to one fetch. The view models' `isLoading`
    /// guards remain the backstop.
    ///
    /// The position comes from ``LibraryBrowserView/rowIndexById``, built alongside
    /// the rows themselves, so a burst of `onAppear`s costs O(1) lookups rather than
    /// re-deriving and re-scanning the whole window once per row.
    func loadMoreIfNeeded(_ row: LibraryTrackRow) {
        guard hasMoreTracks, !prefetchGate.isFetching else { return }
        guard let index = rowIndexById[row.id],
              LibraryPagination.shouldPrefetch(index: index, count: derivedRows.count)
        else { return }
        guard prefetchGate.begin() else { return }
        Task {
            await loadNextPage()
            prefetchGate.end()
        }
    }

    /// Appends one keyset page to whichever window drives the browser, then
    /// republishes the row snapshot the list renders from.
    ///
    /// Search grows differently and returns early: ranked relevance has no stable
    /// keyset cursor, so its next "page" is a wider `LIMIT`, and its rows are read
    /// straight off the model rather than through `sourceTracks` — leaving the
    /// browse window exactly as the search found it.
    func loadNextPage() async {
        guard !localSearch.isActive else {
            await localSearch.loadMore()
            return
        }
        if filterRootPath != nil {
            try? await folderModel?.loadMore()
        } else if let genreModel {
            try? await genreModel.loadMore()
        } else {
            try? await environment.library.loadMoreTracks()
        }
        syncSourceTracks()
    }

    /// Tops a freshly loaded window up to ``LibraryPagination/viewportFillTarget``
    /// rows so a tall window starts filled rather than stalling on first scroll.
    ///
    /// Bounded twice over — at most ``LibraryPagination/viewportFillMaxPages``
    /// pages, and never past the row target — so this is a top-up, never a
    /// fetch-all. It claims the same gate as the scroll prefetch, so a row that
    /// appears mid-fill does not race a second page in.
    func fillViewportIfNeeded() async {
        guard prefetchGate.begin() else { return }
        defer { prefetchGate.end() }
        var fetched = 0
        while fetched < LibraryPagination.viewportFillMaxPages,
              hasMoreTracks,
              loadedTrackCount < LibraryPagination.viewportFillTarget
        {
            await loadNextPage()
            fetched += 1
        }
    }
}
