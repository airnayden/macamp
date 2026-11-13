import Foundation
import GRDB

/// v15 schema helpers — the listening-statistics substrate.
///
/// Split out of the base migrations file so it stays within the file-length budget,
/// mirroring `AppDatabase+Migrations+Profiles.swift`. These are `internal static`
/// only because the `migrator` that invokes them lives in the sibling file; they stay
/// scoped to `Persistence` and are called exclusively from the frozen `"v15"` block.
extension AppDatabase {
    /// One row per play, denormalised at capture so the history outlives its source.
    ///
    /// `trackId` is a **bare `INTEGER` with no foreign key** — a best-effort backlink
    /// only. That is the whole point of this table: deleting a track, a playlist or an
    /// entire library root must leave the event untouched, so the artist/title/album/
    /// genre are snapshotted here rather than joined at read time. Only `profileId`
    /// cascades.
    ///
    /// `utcOffsetSeconds` stores the capture-time offset east of GMT, which lets
    /// hour-of-day facets mean the listener's local night without ever consulting a
    /// `Calendar` at read time. `sourceSurface` is nullable because playback can start
    /// without a navigable source, matching `profilePlaybackState.sourceJson` (v14).
    static func createPlayEventTable(_ db: Database) throws {
        try db.create(table: "playEvent") { table in
            table.primaryKey("id", .integer)
            table.column("profileId", .integer)
                .notNull()
                .references("profile", onDelete: .cascade)
            table.column("trackId", .integer)
            table.column("artistName", .text)
            table.column("title", .text)
            table.column("albumTitle", .text)
            table.column("genre", .text)
            table.column("durationSeconds", .double)
            table.column("startedAt", .double).notNull()
            table.column("utcOffsetSeconds", .integer).notNull()
            table.column("secondsListened", .double).notNull().defaults(to: 0)
            table.column("completionFraction", .double).notNull().defaults(to: 0)
            table.column("skipped", .integer).notNull().defaults(to: 0)
            table.column("sourceSurface", .text)
            table.column("shuffle", .integer).notNull().defaults(to: 0)
        }
        try db.create(
            index: "playEvent_on_profileId_startedAt",
            on: "playEvent",
            columns: ["profileId", "startedAt"]
        )
        try db.create(
            index: "playEvent_on_profileId_trackId",
            on: "playEvent",
            columns: ["profileId", "trackId"]
        )
    }

    /// Permanent monthly summaries that survive the 24-month raw-event horizon.
    ///
    /// `artistKey`/`genreKey` are NOT NULL because SQL treats `NULL != NULL`: an
    /// unknown artist stored as NULL would land in its own bucket on every `GROUP BY`
    /// and break the `UNIQUE` key the compactor upserts against. Callers collapse an
    /// absent value to the empty-string sentinel instead.
    static func createPlayEventRollupTable(_ db: Database) throws {
        try db.create(table: "playEventRollup") { table in
            table.primaryKey("id", .integer)
            table.column("profileId", .integer)
                .notNull()
                .references("profile", onDelete: .cascade)
            table.column("yearMonth", .text).notNull()
            table.column("artistKey", .text).notNull()
            table.column("genreKey", .text).notNull()
            table.column("plays", .integer).notNull().defaults(to: 0)
            table.column("listenedSeconds", .double).notNull().defaults(to: 0)
            table.column("skips", .integer).notNull().defaults(to: 0)
            table.column("completions", .integer).notNull().defaults(to: 0)
            table.uniqueKey(["profileId", "yearMonth", "artistKey", "genreKey"])
        }
        try db.create(
            index: "playEventRollup_on_profileId_yearMonth",
            on: "playEventRollup",
            columns: ["profileId", "yearMonth"]
        )
    }

    /// Manual track order within one library root, keyed by `(profileId, rootPath,
    /// trackId)`.
    ///
    /// Keyed by root rather than stored as a single per-track column because nested and
    /// overlapping roots each need their own independent order. Unlike `playEvent`,
    /// order rows carry no survivability duty, so `trackId` is a real cascading foreign
    /// key. Favourites keep using `profileTrackState.customPosition`; the two orderings
    /// are deliberately separate mechanisms.
    static func createFolderTrackOrderTable(_ db: Database) throws {
        try db.create(table: "folderTrackOrder") { table in
            table.column("profileId", .integer)
                .notNull()
                .references("profile", onDelete: .cascade)
            table.column("rootPath", .text).notNull()
            table.column("trackId", .integer)
                .notNull()
                .references("track", onDelete: .cascade)
            table.column("position", .integer).notNull()
            table.primaryKey(["profileId", "rootPath", "trackId"])
        }
        try db.create(
            index: "folderTrackOrder_on_profileId_rootPath_position",
            on: "folderTrackOrder",
            columns: ["profileId", "rootPath", "position"]
        )
    }

    /// The per-track replay heatmap: which *parts* of a song get replayed.
    ///
    /// `bucketCounts` is exactly 400 bytes — 100 little-endian `UInt32` listen counts,
    /// where bucket `i` covers `[i%, (i+1)%)` of the track's duration. Storing relative
    /// buckets rather than absolute seconds keeps one fixed-width blob per track.
    /// `trackId` is bare and non-foreign-key for the same survivability reason as
    /// `playEvent`; the metadata is likewise snapshotted here.
    static func createPlaySegmentHeatTable(_ db: Database) throws {
        try db.create(table: "playSegmentHeat") { table in
            table.primaryKey("id", .integer)
            table.column("profileId", .integer)
                .notNull()
                .references("profile", onDelete: .cascade)
            table.column("trackId", .integer).notNull()
            table.column("artistName", .text)
            table.column("title", .text)
            table.column("albumTitle", .text)
            table.column("genre", .text)
            table.column("durationSeconds", .double).notNull()
            table.column("bucketCounts", .blob).notNull()
            table.column("totalPasses", .integer).notNull().defaults(to: 0)
            table.column("updatedAt", .double).notNull()
            table.uniqueKey(["profileId", "trackId"])
        }
    }
}
