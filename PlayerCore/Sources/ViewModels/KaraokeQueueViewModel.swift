// KaraokeQueueViewModel — resolves display rows (title/artist) for the karaoke
// render queue so the Karaoke Queue sidebar section can show the in-flight item with
// a progress bar plus the pending items. It resolves the current + pending source
// paths a ``KaraokeQueueStore`` reports through the same profile-scoped
// ``KaraokeReadyPaging`` seam (`TrackRepository.tracksByPaths`) the ready list uses,
// then REORDERS the `(sortTitle, id)`-sorted query result back into QUEUE order —
// the queue's order is authoritative, not the library sort order. The read runs OFF
// the main actor (`Task.detached`). The view re-invokes
// ``resolve(currentPath:pendingPaths:)`` on store `version` (membership) and profile
// changes; this view model owns only the resolved rows.
//
// The queue is small (bounded by the render backlog), so — unlike
// ``KaraokeReadyListViewModel`` — this resolves the whole set in ONE bounded call
// (`limit == path count`) rather than keyset-paginating.
import Observation
import Persistence

/// Resolves the karaoke render queue's source paths into display rows for the active
/// profile, split into the in-flight ``currentRow`` and the ``pendingRows`` in queue
/// order.
///
/// Rows come from ``KaraokeReadyPaging`` (the same seam ``KaraokeReadyListViewModel``
/// uses), which returns them in `(sortTitle, id)` order; this view model reorders
/// them back into queue order because the queue — not the library sort — dictates
/// display order.
@MainActor
@Observable
public final class KaraokeQueueViewModel {
    /// The resolved row for the render in flight, or `nil` when idle or unresolved
    /// (e.g. the source is no longer in the active profile's library).
    public private(set) var currentRow: ProfileScopedTrack?

    /// The resolved rows for the pending queue, in QUEUE (FIFO) order — NOT the
    /// `(sortTitle, id)` order the query returns.
    public private(set) var pendingRows: [ProfileScopedTrack] = []

    /// `true` while a resolve is in flight.
    public private(set) var isLoading = false

    @ObservationIgnored private let repository: any KaraokeReadyPaging

    /// The profile this queue is scoped to (Guest by default). Re-assigned by the view
    /// on a profile switch before it calls ``resolve(currentPath:pendingPaths:)`` again.
    @ObservationIgnored public var activeProfileId: Int64

    public init(
        repository: any KaraokeReadyPaging,
        activeProfileId: Int64 = ProfileRecord.guestID
    ) {
        self.repository = repository
        self.activeProfileId = activeProfileId
    }

    /// Resolves display rows for the queue's `currentPath` + `pendingPaths`.
    ///
    /// The `(sortTitle, id)`-ordered query result is reordered back into queue order:
    /// ``currentRow`` is the current path's row (if it resolves) and ``pendingRows``
    /// follows `pendingPaths` verbatim, dropping any path with no row in the active
    /// profile's library. An empty queue clears both.
    ///
    /// A path that backs SEVERAL rows (a `.cue` sheet's segments, or a suppressed
    /// whole-file row beside them) expands to all of them in `(cueStartFrame, id)`
    /// order, so `pendingRows` may be longer than `pendingPaths`.
    public func resolve(currentPath: String?, pendingPaths: [String]) async throws {
        let queuePaths = (currentPath.map { [$0] } ?? []) + pendingPaths
        guard !queuePaths.isEmpty else {
            currentRow = nil
            pendingRows = []
            return
        }
        isLoading = true
        defer { isLoading = false }
        let rows = try await fetchRows(paths: queuePaths)
        let rowsByPath = Self.groupedByPath(rows)
        currentRow = currentPath.flatMap { rowsByPath[$0]?.first }
        pendingRows = pendingPaths.flatMap { rowsByPath[$0] ?? [] }
    }

    /// Groups the query result by audio `filePath`, keeping EVERY row for a path.
    ///
    /// Post-v20 a path no longer names one row: a `.cue` sheet backs N `track` rows
    /// on one audio file, distinguished only by ``TrackRecord/Identity``'s
    /// `cueStartFrame`. The `Dictionary(_:uniquingKeysWith:)` collapse this replaces
    /// kept the FIRST row per path, so an N-segment file rendered as a single queue
    /// row. Ordering is `(cueStartFrame, id)` so the grouping is deterministic and a
    /// whole-file row — whose `-1` sentinel sorts below every real frame — leads its
    /// own segments.
    private static func groupedByPath(
        _ rows: [ProfileScopedTrack]
    ) -> [String: [ProfileScopedTrack]] {
        var grouped: [String: [ProfileScopedTrack]] = [:]
        for row in rows {
            grouped[row.track.filePath, default: []].append(row)
        }
        return grouped.mapValues { group in
            group.sorted { lhs, rhs in
                (lhs.track.cueStartFrame, lhs.track.id ?? 0) < (rhs.track.cueStartFrame, rhs.track.id ?? 0)
            }
        }
    }

    /// The most `track` rows one audio path can back: `TRACK nn` in a `.cue` sheet is
    /// two digits, so 99 segments, plus the retained whole-file row todo 30 suppresses
    /// rather than deletes.
    private static let maximumRowsPerPath = 100

    /// A hard ceiling on one resolve, so a pathological queue can never ask for an
    /// unbounded page (PlayerCore's bounded-read invariant).
    private static let resolveRowLimit = 500

    private func fetchRows(paths: [String]) async throws -> [ProfileScopedTrack] {
        let repository = repository
        let profileId = activeProfileId
        // `paths.count` is a FLOOR on the row count post-v20, not the count: using it
        // as the limit truncated an N-segment cue album to its first row.
        let limit = min(paths.count * Self.maximumRowsPerPath, Self.resolveRowLimit)
        return try await Task.detached {
            try repository.readyTracks(profileId: profileId, paths: paths, after: nil, limit: limit)
        }.value
    }
}
