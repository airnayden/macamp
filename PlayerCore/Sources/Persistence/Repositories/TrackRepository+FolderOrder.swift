import GRDB

/// A folder-page row: the track plus the sort key its cursor resumes from, which
/// must travel beside it because ``TrackRecord`` carries no folder position.
struct FolderOrderedTrack: FetchableRecord {
    let track: TrackRecord
    let orderKey: Int64

    init(row: Row) throws {
        track = try TrackRecord(row: row)
        let key: Int64? = row[TrackRepository.folderOrderKeyColumn]
        orderKey = key ?? TrackRepository.unpositionedFolderOrderKey
    }
}

/// The profile's **manual track order within one library root** — what the folder
/// browser's drag-reorder writes and what `tracksByRoot` renders.
///
/// Folder order lives in its own `folderTrackOrder` table (v15), keyed by
/// `(profileId, rootPath, trackId)`, and is deliberately independent of Favourites'
/// `profileTrackState.customPosition`: reordering a folder never touches a
/// favourite's position, and reordering Favourites never moves a folder row. Keying
/// by root (rather than by track) is what lets nested and overlapping roots hold
/// their own orders.
public extension TrackRepository {
    /// Persists this profile's manual order for the tracks under `rootPath`.
    ///
    /// `updates` describes only the rows the user can actually drag — the loaded
    /// keyset window. The **first** reorder of a root therefore also backfills a
    /// position for *every* track beneath it, so the rows below the window keep a
    /// defined place instead of collapsing into the un-positioned tail. Backfill and
    /// move share ONE transaction and the backfill is set-based SQL
    /// (`ROW_NUMBER() OVER (…)`, no array materialisation), so the write stays
    /// bounded on a 100k-track root and an interrupted reorder rolls the root all
    /// the way back to having no custom order.
    ///
    /// Positions are ascending from `0`; a trailing slash on `rootPath` is
    /// normalised, so `/Music` and `/Music/` address the same order.
    func updateFolderPositions(
        profileId: Int64 = ProfileRecord.guestID,
        rootPath: String,
        _ updates: [(trackId: Int64, position: Int)]
    ) async throws {
        let rootKey = Self.canonicalRootKey(rootPath)
        let pattern = Self.likePrefixPattern(forRoot: rootPath)
        try await dbWriter.write { db in
            try Self.backfillFolderOrder(db, profileId: profileId, rootKey: rootKey, pattern: pattern)
            for update in updates {
                try db.execute(sql: """
                INSERT INTO folderTrackOrder (profileId, rootPath, trackId, position)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(profileId, rootPath, trackId) DO UPDATE SET position = excluded.position
                """, arguments: [profileId, rootKey, update.trackId, update.position])
            }
        }
    }

    /// Every order row this profile holds for one root, ascending. Bounded by the
    /// root's track count and used by tests and diagnostics, never by the browser
    /// (which pages through ``tracksByRoot`` instead).
    func folderPositions(
        profileId: Int64 = ProfileRecord.guestID,
        rootPath: String
    ) throws -> [FolderTrackOrderRecord] {
        let rootKey = Self.canonicalRootKey(rootPath)
        return try dbWriter.read { db in
            try FolderTrackOrderRecord
                .filter(FolderTrackOrderRecord.Columns.profileId == profileId)
                .filter(FolderTrackOrderRecord.Columns.rootPath == rootKey)
                .order(FolderTrackOrderRecord.Columns.position)
                .fetchAll(db)
        }
    }
}

extension TrackRepository {
    /// The position an un-positioned row sorts at.
    ///
    /// A track the scanner adds after a reorder has no order row. Ordering by the
    /// raw column would put those `NULL`s **first** in SQLite and jump brand-new
    /// files to the top of the folder; coalescing them to the largest representable
    /// position parks them after every positioned row instead, still tie-broken by
    /// `track.id` so the tail order is deterministic.
    static let unpositionedFolderOrderKey = Int64.max

    /// The folder page's sort key — and, identically, its keyset cursor key.
    ///
    /// Sort key and cursor key must be the same expression: paging by `track.id`
    /// while ordering by position is exactly what made `loadMore` skip and duplicate
    /// rows after a reorder. Requires the `fto` alias for `folderTrackOrder` to be
    /// joined for the (profile, root) pair.
    static let folderOrderKeySQL = "COALESCE(fto.position, \(unpositionedFolderOrderKey))"

    /// The alias ``folderOrderKeySQL`` is selected under, so the page can read the
    /// key back without re-deriving it. `TrackRecord` ignores the extra column.
    static let folderOrderKeyColumn = "folderOrderKey"

    /// The `folderTrackOrder.rootPath` value addressing a library-root path, with
    /// trailing slashes stripped so `/Music` and `/Music/` share one order.
    static func canonicalRootKey(_ rootPath: String) -> String {
        var key = rootPath
        while key.hasSuffix("/"), key.count > 1 {
            key.removeLast()
        }
        return key
    }

    /// Seeds a position for every track under the root, the first time that root is
    /// reordered. A no-op once any order row exists, so later reorders only rewrite
    /// the window the user actually dragged and scanner-added tracks keep appending
    /// to the un-positioned tail.
    ///
    /// The seed order is `track.id`, which is precisely the order the folder page
    /// renders while no positions exist — so the backfill is invisible on its own.
    static func backfillFolderOrder(
        _ db: Database,
        profileId: Int64,
        rootKey: String,
        pattern: String
    ) throws {
        let alreadySeeded = try Bool.fetchOne(db, sql: """
        SELECT EXISTS(SELECT 1 FROM folderTrackOrder WHERE profileId = ? AND rootPath = ?)
        """, arguments: [profileId, rootKey]) ?? false
        guard !alreadySeeded else { return }
        try db.execute(sql: """
        INSERT INTO folderTrackOrder (profileId, rootPath, trackId, position)
        SELECT ?, ?, ordered.id, ordered.ordinal - 1 FROM (
          SELECT track.id AS id, ROW_NUMBER() OVER (ORDER BY track.id) AS ordinal
          FROM track WHERE track.filePath LIKE ? ESCAPE '\\'
        ) AS ordered
        """, arguments: [profileId, rootKey, pattern])
    }
}
