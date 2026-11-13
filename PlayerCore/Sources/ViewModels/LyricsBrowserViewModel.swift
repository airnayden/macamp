// LyricsBrowserViewModel — the keyset-paginated window over the tracks whose
// lyrics are already cached, plus the browser's own lyrics preview.
//
// Shaped like ``GenreBrowserViewModel``: one keyset window, reads OFF the main
// actor (`Task.detached`) so the main thread never blocks on a GRDB reader, and
// an `activeProfileId` the profile-switch seam re-assigns before reloading.
//
// The preview is deliberately a SECOND ``LyricsViewModel`` that this model
// constructs and owns. Previewing an arbitrary track must never disturb the
// now-playing lyrics, so the browser is given a ``LyricsProviding`` and builds
// its own resolver — it is never handed, and cannot reach, the now-playing model.
//
// This file MUST NOT import AppKit or UIKit (PlayerCore portability invariant).
import Foundation
import Lyrics
import Observation
import Persistence
import Services

/// Paginates the tracks that have cached lyrics and previews any one of them.
@MainActor
@Observable
public final class LyricsBrowserViewModel {
    /// Accumulated keyset pages, ordered by `(sortTitle, id)`.
    public private(set) var tracks: [LyricsRowDTO] = []
    /// `true` while a page is being fetched.
    public private(set) var isLoading = false
    /// `false` once the last page has been loaded.
    public private(set) var hasMore = true
    /// Every track with cached lyrics for this profile, not just the loaded
    /// window — the empty-state signal. Refreshed by ``loadInitial()``.
    public private(set) var totalCount = 0

    /// The track being previewed, or `nil` when the UI should show now-playing.
    public private(set) var previewTrack: TrackRef?

    /// The preview resolver. Separate from the now-playing lyrics model by
    /// construction, so a preview can never mutate playback's lyrics state.
    @ObservationIgnored public let previewLyrics: LyricsViewModel

    @ObservationIgnored private let repository: any LyricsBrowsing
    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private let refreshDebounce: Duration
    @ObservationIgnored private var cursor: PageCursor<String>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    /// The profile this window is scoped to (Guest by default). Re-assigned by the
    /// profile-switch seam, which then calls ``loadInitial()`` again.
    @ObservationIgnored public var activeProfileId: Int64

    public init(
        repository: any LyricsBrowsing,
        provider: any LyricsProviding,
        pageSize: Int = 100,
        activeProfileId: Int64 = ProfileRecord.guestID,
        refreshDebounce: Duration = .milliseconds(300)
    ) {
        self.repository = repository
        previewLyrics = LyricsViewModel(provider: provider)
        self.pageSize = max(1, pageSize)
        self.activeProfileId = activeProfileId
        self.refreshDebounce = refreshDebounce
    }

    /// Reloads the window after the lyrics cache gains a document.
    ///
    /// The sweep walks in the background and commits rows long after this list
    /// loaded; `.task(id:)` only re-reads on re-mount, so swept tracks would stay
    /// invisible for the rest of the session without this seam.
    ///
    /// Debounced: a lyric-rich library signals per track, and coalescing the burst
    /// keeps a reload to one bounded page + count, both off-main in ``loadInitial()``.
    public func cacheDidChange() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: refreshDebounce)
            guard !Task.isCancelled else { return }
            try? await loadInitial()
        }
    }

    /// Test/synchronization seam: returns once a pending ``cacheDidChange()`` reload
    /// has finished.
    public func waitForPendingRefresh() async {
        await refreshTask?.value
    }

    /// Loads (or reloads) the first keyset page and refreshes ``totalCount``.
    ///
    /// Assigns `tracks` atomically after the fetch resolves — it must not clear
    /// `tracks` up front nor route through the `isLoading`-guarded ``loadMore()``,
    /// which would let a concurrent reload wipe the window and then early-return.
    /// Mirrors ``GenreBrowserViewModel/loadInitial()``.
    public func loadInitial() async throws {
        isLoading = true
        defer { isLoading = false }
        let profileId = activeProfileId
        let (page, total) = try await fetchInitial(profileId: profileId)
        tracks = page.items
        cursor = page.nextCursor
        hasMore = page.nextCursor != nil
        totalCount = total
    }

    /// Appends the next keyset page, if any.
    public func loadMore() async throws {
        guard hasMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let page = try await fetchPage(profileId: activeProfileId, after: cursor)
        tracks.append(contentsOf: page.items)
        cursor = page.nextCursor
        hasMore = page.nextCursor != nil
    }

    /// Previews `track`'s lyrics without touching playback.
    ///
    /// `options` is the caller's policy — the shell passes `.online` only when the
    /// user has opted into online lyrics, `.offline` otherwise.
    public func select(_ track: TrackRef, options: LyricsOptions = .default) {
        previewTrack = track
        previewLyrics.resolve(request: Self.request(for: track), options: options)
    }

    /// Drops the preview and returns the UI to now-playing.
    public func clearPreview() {
        previewTrack = nil
        previewLyrics.clear()
    }

    /// The same request shape the now-playing lyrics panel builds, so a preview
    /// and a play of the same track resolve to (and cache under) the same key.
    private static func request(for track: TrackRef) -> LyricsRequest {
        LyricsRequest(
            trackURL: URL(fileURLWithPath: track.filePath),
            title: track.title,
            artist: track.artist,
            album: nil,
            duration: track.duration
        )
    }

    private func fetchInitial(profileId: Int64) async throws -> (Page<LyricsRowDTO, String>, Int) {
        let repository = repository
        let pageSize = pageSize
        return try await Task.detached {
            let page = try repository.tracksWithLyrics(profileId: profileId, after: nil, limit: pageSize)
            let total = try repository.tracksWithLyricsCount(profileId: profileId)
            return (page, total)
        }.value
    }

    private func fetchPage(
        profileId: Int64,
        after cursor: PageCursor<String>?
    ) async throws -> Page<LyricsRowDTO, String> {
        let repository = repository
        let pageSize = pageSize
        return try await Task.detached {
            try repository.tracksWithLyrics(profileId: profileId, after: cursor, limit: pageSize)
        }.value
    }
}

public extension LyricsRowDTO {
    /// A ``TrackRef`` addressing this row's backing file — the argument
    /// ``LyricsBrowserViewModel/select(_:options:)`` and `setQueue` both take.
    ///
    /// Availability is ``Availability/present`` because the browse query returns
    /// only present tracks.
    var trackRef: TrackRef {
        TrackRef(
            trackID: trackId,
            filePath: filePath,
            title: title,
            artist: artist,
            duration: duration,
            availability: .present
        )
    }
}
