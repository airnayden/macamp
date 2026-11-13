import GRDB

/// Profile-scoped per-user state on the `track` table — favourites, play/listen
/// counters and custom order — routed through the sparse `profileTrackState`
/// table (composite PK `(profileId, trackId)`) instead of the now-frozen `track`
/// columns.
///
/// - **Writes** are a single atomic `INSERT … ON CONFLICT(profileId, trackId) DO
///   UPDATE` (UPSERT): the sparse row appears on the first write and is mutated in
///   place thereafter — never a race-prone SELECT-then-INSERT-or-UPDATE.
/// - **Reads** resolve each track's state for one profile and hand back a
///   ``ProfileScopedTrack`` so callers stop reading the frozen ``TrackRecord``
///   user-state columns. ``resolvedTrack(profileId:trackId:)`` uses the
///   `LEFT JOIN … COALESCE` shape (absent row → `0`/`false`); the favourites and
///   top-played reads drive from `profileTrackState` so the
///   `(profileId, isFavourite, customPosition)` covering index does the work.
///
/// Every state API takes `profileId` and defaults it to ``ProfileRecord/guestID``
/// (Guest, id 1), so call sites that have not yet been migrated to pass an active
/// profile keep compiling and resolve to Guest. ``favouriteTracks(limit:)`` /
/// ``topPlayedTracks(limit:)`` additionally keep a `[TrackRecord]`-returning
/// overload for the same reason.
public extension TrackRepository {
    // MARK: - Writes (single-statement UPSERT)

    /// Flips this profile's favourite flag for one track and returns the new state.
    ///
    /// A single UPSERT: the first write inserts the sparse row as a favourite; a
    /// subsequent write toggles the existing value in place. Throws if `profileId`
    /// or `trackId` does not exist (foreign key).
    @discardableResult
    func toggleFavourite(profileId: Int64 = ProfileRecord.guestID, trackId: Int64) async throws -> Bool {
        try await dbWriter.write { db in
            try Bool.fetchOne(db, sql: """
            INSERT INTO profileTrackState (profileId, trackId, isFavourite)
            VALUES (?, ?, 1)
            ON CONFLICT(profileId, trackId) DO UPDATE SET isFavourite = NOT isFavourite
            RETURNING isFavourite
            """, arguments: [profileId, trackId]) ?? true
        }
    }

    /// Sets this profile's favourite flag for one track to an explicit value
    /// (idempotent). Single UPSERT.
    func setFavourite(profileId: Int64 = ProfileRecord.guestID, trackId: Int64, isFavourite: Bool) async throws {
        try await dbWriter.write { db in
            try db.execute(sql: """
            INSERT INTO profileTrackState (profileId, trackId, isFavourite)
            VALUES (?, ?, ?)
            ON CONFLICT(profileId, trackId) DO UPDATE SET isFavourite = excluded.isFavourite
            """, arguments: [profileId, trackId, isFavourite])
        }
    }

    /// Increments this profile's completed-play counter for one track. Single
    /// UPSERT (inserts the sparse row at `1` on first play).
    func incrementPlayCount(profileId: Int64 = ProfileRecord.guestID, trackId: Int64) async throws {
        try await dbWriter.write { db in
            try db.execute(sql: """
            INSERT INTO profileTrackState (profileId, trackId, playCount)
            VALUES (?, ?, 1)
            ON CONFLICT(profileId, trackId) DO UPDATE SET playCount = playCount + 1
            """, arguments: [profileId, trackId])
        }
    }

    /// Increments this profile's completed-listen counter for one track. Single
    /// UPSERT (inserts the sparse row at `1` on first listen).
    func incrementListenedCount(profileId: Int64 = ProfileRecord.guestID, trackId: Int64) async throws {
        try await dbWriter.write { db in
            try db.execute(sql: """
            INSERT INTO profileTrackState (profileId, trackId, listenedCount)
            VALUES (?, ?, 1)
            ON CONFLICT(profileId, trackId) DO UPDATE SET listenedCount = listenedCount + 1
            """, arguments: [profileId, trackId])
        }
    }

    /// Persists this profile's custom display positions for a batch of tracks. Each
    /// entry is a single UPSERT inside one write transaction.
    func updateCustomPositions(
        profileId: Int64 = ProfileRecord.guestID,
        _ updates: [(trackId: Int64, position: Int)]
    ) async throws {
        try await dbWriter.write { db in
            for update in updates {
                try db.execute(sql: """
                INSERT INTO profileTrackState (profileId, trackId, customPosition)
                VALUES (?, ?, ?)
                ON CONFLICT(profileId, trackId) DO UPDATE SET customPosition = excluded.customPosition
                """, arguments: [profileId, update.trackId, update.position])
            }
        }
    }

    // MARK: - Reads (profile-resolved DTO)

    /// One track resolved against a profile's state via `LEFT JOIN … COALESCE`, so
    /// a track with no `profileTrackState` row still resolves (favourite `false`,
    /// counts `0`, custom position `nil`). Returns `nil` only when the track id
    /// does not exist. The single-track seam Task 7 uses for favourite buttons/rows.
    func resolvedTrack(profileId: Int64 = ProfileRecord.guestID, trackId: Int64) throws -> ProfileScopedTrack? {
        try dbWriter.read { db in
            try ProfileScopedTrack.fetchOne(db, sql: """
            SELECT track.*, \(ProfileScopedTrack.resolvedColumnsSQL)
            FROM track
            \(ProfileScopedTrack.profileStateLeftJoinSQL)
            WHERE track.id = ?
            """, arguments: [profileId, trackId])
        }
    }

    /// A bounded batch of tracks resolved against one profile's state, keyed by
    /// `track.id` — the many-ids counterpart of ``resolvedTrack(profileId:trackId:)``
    /// that the listening-stats surface uses to hydrate a whole page of history in one
    /// round-trip instead of one query per row.
    ///
    /// Drives from `track` with the `LEFT JOIN … COALESCE` shape (unlike
    /// ``topPlayedTracks(profileId:limit:)``, which drives from `profileTrackState`
    /// with an INNER JOIN), so a track this profile holds **no** state row for still
    /// resolves — favourite `false`, counts `0`, custom position `nil`. An id that no
    /// longer exists in the library is simply absent from the result, so a caller
    /// detects a pruned track by a `nil` lookup rather than an error.
    ///
    /// Bounded twice over: duplicate ids collapse and at most 500 survive, so the
    /// statement binds at most 501 variables — the profile id plus the `IN (…)` list —
    /// against SQLite's 999-parameter ceiling, leaving roughly half of it unspent
    /// however long the caller's id list grows (the stats surface batches its unions
    /// into 100-id calls). An empty input short-circuits and never opens a read.
    ///
    /// Deliberately **not** filtered by ``LibraryVisibility``: play history resolves by
    /// id and must keep rendering its titles even when the file now sits outside this
    /// profile's current library roots. Root scoping governs *browsing*, never what the
    /// profile has already listened to.
    func resolvedTracks(profileId: Int64, trackIds: [Int64]) async throws -> [Int64: ProfileScopedTrack] {
        let ids = Array(Set(trackIds).prefix(500))
        guard !ids.isEmpty else { return [:] }
        return try await dbWriter.read { db in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
            var arguments: [any DatabaseValueConvertible] = [profileId]
            arguments.append(contentsOf: ids)
            let rows = try ProfileScopedTrack.fetchAll(db, sql: """
            SELECT track.*, \(ProfileScopedTrack.resolvedColumnsSQL)
            FROM track
            \(ProfileScopedTrack.profileStateLeftJoinSQL)
            WHERE track.id IN (\(placeholders))
            """, arguments: StatementArguments(arguments))
            var resolved: [Int64: ProfileScopedTrack] = [:]
            resolved.reserveCapacity(rows.count)
            for row in rows {
                guard let trackId = row.track.id else { continue }
                resolved[trackId] = row
            }
            return resolved
        }
    }

    /// Every track this profile favourited, ordered by the profile's
    /// `customPosition` when any favourite has one (the user drag-reordered the
    /// Favourites list), else by `id`.
    ///
    /// Drives from `profileTrackState` (`WHERE profileId = ? AND isFavourite = 1`),
    /// so the `(profileId, isFavourite, customPosition)` covering index selects and
    /// orders the sparse favourite rows — never a scan of the whole `track` table.
    /// Favourites are a user-curated subset, so this is a single `LIMIT`-capped
    /// fetch rather than an unbounded load.
    func favouriteTracks(profileId: Int64, limit: Int = 1000) throws -> [ProfileScopedTrack] {
        try dbWriter.read { db in
            let hasCustomOrder = try Bool.fetchOne(db, sql: """
            SELECT EXISTS(
              SELECT 1 FROM profileTrackState
              WHERE profileId = ? AND isFavourite = 1 AND customPosition IS NOT NULL
            )
            """, arguments: [profileId]) ?? false
            let orderClause = hasCustomOrder ? "pts.customPosition" : "track.id"
            return try ProfileScopedTrack.fetchAll(db, sql: """
            SELECT track.*, \(ProfileScopedTrack.resolvedColumnsSQL)
            FROM profileTrackState pts
            JOIN track ON track.id = pts.trackId
            WHERE pts.profileId = ? AND pts.isFavourite = 1
            ORDER BY \(orderClause)
            LIMIT ?
            """, arguments: [profileId, max(1, limit)])
        }
    }

    /// Guest-scoped backward-compatible favourites read (returns bare
    /// ``TrackRecord``s). Retained so pre-migration call sites keep compiling; Task 7
    /// migrates them to the `profileId:` DTO overload above.
    func favouriteTracks(limit: Int = 1000) throws -> [TrackRecord] {
        try favouriteTracks(profileId: ProfileRecord.guestID, limit: limit).map(\.track)
    }

    /// This profile's most-played tracks (descending `playCount`), each carrying the
    /// profile-resolved counts. Drives from `profileTrackState`
    /// (`WHERE profileId = ? AND playCount > 0`), `LIMIT`-capped.
    func topPlayedTracks(profileId: Int64, limit: Int = 20) async throws -> [ProfileScopedTrack] {
        try await dbWriter.read { db in
            try ProfileScopedTrack.fetchAll(db, sql: """
            SELECT track.*, \(ProfileScopedTrack.resolvedColumnsSQL)
            FROM profileTrackState pts
            JOIN track ON track.id = pts.trackId
            WHERE pts.profileId = ? AND pts.playCount > 0
            ORDER BY pts.playCount DESC
            LIMIT ?
            """, arguments: [profileId, max(1, limit)])
        }
    }

    /// Guest-scoped backward-compatible top-played read (returns bare
    /// ``TrackRecord``s). Retained so pre-migration call sites keep compiling; Task 7
    /// migrates them to the `profileId:` DTO overload above.
    func topPlayedTracks(limit: Int = 20) async throws -> [TrackRecord] {
        try await topPlayedTracks(profileId: ProfileRecord.guestID, limit: limit).map(\.track)
    }

    /// This profile's total play count across all tracks. Sums the profile's sparse
    /// `profileTrackState` rows (`0` when the profile has played nothing).
    func totalPlayCount(profileId: Int64 = ProfileRecord.guestID) async throws -> Int {
        try await dbWriter.read { db in
            try Int.fetchOne(db, sql: """
            SELECT COALESCE(SUM(playCount), 0) FROM profileTrackState WHERE profileId = ?
            """, arguments: [profileId]) ?? 0
        }
    }
}
