import GRDB

/// A ``TrackRecord`` paired with **profile-resolved** user state — the favourite
/// flag, play/listen counts and custom order as they exist for one specific
/// profile in `profileTrackState`, rather than the frozen `track` columns.
///
/// Profile-scoped reads (favourites, top-played, single-track resolution, and —
/// from Task 7 — the whole browse surface) decode into this DTO so views never
/// read the frozen ``TrackRecord/isFavourite`` / ``TrackRecord/playCount`` /
/// ``TrackRecord/listenedCount`` / ``TrackRecord/customPosition`` columns
/// directly. A track with **no** `profileTrackState` row for the profile resolves
/// to `isFavourite = false` and every count `0` (via `COALESCE`), so the sparse
/// rows are transparent to callers.
///
/// The embedded ``track`` still physically carries its frozen columns (they are
/// selected as part of `track.*`), but they are historical/dead — read user
/// state from the `resolved*` fields below, never from ``track``.
public struct ProfileScopedTrack: Sendable, Equatable, Hashable {
    /// The underlying track row (identity, tags, availability, stream info).
    public var track: TrackRecord
    /// Whether THIS profile favourited the track. `false` when the profile has no
    /// state row for it.
    public var isFavourite: Bool
    /// THIS profile's completed play count (`0` when unplayed by the profile).
    public var playCount: Int
    /// THIS profile's completed listen count (`0` when never listened by the profile).
    public var listenedCount: Int
    /// THIS profile's custom display position, or `nil` when unset.
    public var customPosition: Int?

    public init(
        track: TrackRecord,
        isFavourite: Bool = false,
        playCount: Int = 0,
        listenedCount: Int = 0,
        customPosition: Int? = nil
    ) {
        self.track = track
        self.isFavourite = isFavourite
        self.playCount = playCount
        self.listenedCount = listenedCount
        self.customPosition = customPosition
    }
}

extension ProfileScopedTrack: FetchableRecord {
    /// Decodes `track.*` into ``track`` and the four `resolved*` aliased columns
    /// (produced by ``resolvedColumnsSQL``) into the resolved fields. Any columns
    /// beyond the track's own are ignored by ``TrackRecord``'s decode, so the
    /// `resolved*` aliases must not collide with a `track` column name.
    public init(row: Row) throws {
        track = try TrackRecord(row: row)
        isFavourite = row[Self.resolvedIsFavouriteColumn]
        playCount = row[Self.resolvedPlayCountColumn]
        listenedCount = row[Self.resolvedListenedCountColumn]
        customPosition = row[Self.resolvedCustomPositionColumn]
    }
}

public extension ProfileScopedTrack {
    /// The aliased result-column names ``init(row:)`` decodes. Kept as constants so
    /// the SELECT list and the decoder share one source of truth.
    static let resolvedIsFavouriteColumn = "resolvedIsFavourite"
    static let resolvedPlayCountColumn = "resolvedPlayCount"
    static let resolvedListenedCountColumn = "resolvedListenedCount"
    static let resolvedCustomPositionColumn = "resolvedCustomPosition"

    /// SELECT-list fragment producing the four `resolved*` columns this DTO
    /// decodes. Prefix with `track.*, ` and join `profileTrackState` aliased `pts`.
    /// `COALESCE` makes a sparse (absent) row resolve to `0` / `false`;
    /// `customPosition` stays `NULL`-able (`nil` = unset). Task 7's scoped browse
    /// queries reuse this verbatim.
    static let resolvedColumnsSQL = """
    COALESCE(pts.isFavourite, 0) AS \(resolvedIsFavouriteColumn), \
    COALESCE(pts.playCount, 0) AS \(resolvedPlayCountColumn), \
    COALESCE(pts.listenedCount, 0) AS \(resolvedListenedCountColumn), \
    pts.customPosition AS \(resolvedCustomPositionColumn)
    """

    /// The `LEFT JOIN` that resolves per-profile state for the profile bound to the
    /// single `?` placeholder. A track with no matching row still appears (its `pts`
    /// columns become `NULL` → ``resolvedColumnsSQL``'s `COALESCE` supplies the
    /// defaults). Task 7 reuses this for the scoped browse queries.
    static let profileStateLeftJoinSQL = """
    LEFT JOIN profileTrackState pts ON (pts.profileId = ? AND pts.trackId = track.id)
    """
}
