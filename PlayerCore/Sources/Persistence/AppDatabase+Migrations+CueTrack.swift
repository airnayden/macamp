import Foundation
import GRDB

/// v20 schema helpers — the guarded `track` table rebuild that enables CUE
/// virtual tracks.
///
/// Split out of the base migrations file so it stays within the file-length
/// budget, mirroring `AppDatabase+Migrations+Profiles.swift`,
/// `AppDatabase+Migrations+Stats.swift`, `AppDatabase+Migrations+AI.swift`,
/// `AppDatabase+Migrations+Downloads.swift`,
/// `AppDatabase+Migrations+Loudness.swift` and
/// `AppDatabase+Migrations+TrackSchema.swift`. These are `internal static` only
/// because the `migrator` that invokes them lives in the sibling file; they stay
/// scoped to `Persistence` and are called exclusively from the frozen `"v20"`
/// block.
///
/// ### Why a rebuild, and not an `ALTER TABLE`
///
/// v1 declared `filePath` with a **column** constraint —
/// `table.column("filePath", .text).notNull().unique()`. SQLite cannot drop a
/// column constraint; the only way to replace it with the two-column
/// `UNIQUE(filePath, cueStartFrame)` a cue library needs is the full 12-step
/// rebuild recipe from <https://www.sqlite.org/lang_altertable.html#otheralter>.
///
/// ### The four new columns
///
/// - `cueSheetPath TEXT` — absolute path of the `.cue` sidecar; `NULL` for an
///   ordinary file.
/// - `cueStartFrame INTEGER NOT NULL DEFAULT -1` — `CueTrack.startFrame`; `-1`
///   means whole file, i.e. not a cue segment.
/// - `cueEndFrame INTEGER` — `CueTrack.endFrame`, EXCLUSIVE; `NULL` means to
///   end of file.
/// - `cueSuppressed INTEGER NOT NULL DEFAULT 0` — todo 30's retain-and-hide
///   flag for a pre-existing whole-file row a later `.cue` superseded.
///
/// `cueStartFrame` is deliberately **NOT NULL with a `-1` sentinel** rather than
/// nullable. A plain table-level `UNIQUE(filePath, cueStartFrame)` then works
/// both with `ON CONFLICT(filePath, cueStartFrame)` and with GRDB's key-based
/// helpers, whereas an `IFNULL(...)` expression index matches neither:
/// `ON CONFLICT` rejects it, and `PRAGMA index_info` reports NULL columns so
/// `fetchOne(_:key:)` traps. `-1` is the same sentinel `trackLoudness`
/// (`TrackLoudnessFingerprint.wholeFileCueStartFrame`, v18) already stores.
///
/// ### Foreign keys, and why the migration mode is load-bearing
///
/// `"v20"` is registered with GRDB's **default** `foreignKeyChecks: .deferred`,
/// which wraps the whole migration in `PRAGMA foreign_keys = OFF` and runs
/// `PRAGMA foreign_key_check` before committing. `.immediate` is FORBIDDEN here:
/// with foreign keys live, `DROP TABLE track` would `ON DELETE CASCADE` through
/// **five** child tables — `playlistTrack`, `trackAudioFeature`,
/// `profileTrackState`, `folderTrackOrder` and `trackLoudness` — silently
/// destroying playlist membership, per-profile favourites and every cached
/// analysis. `checkForeignKeys()` is also called explicitly at the end of
/// ``rebuildTrackForCueSupport(_:)`` so the recipe's step 10 is visible in this
/// code and still runs if the connection ever arrives with foreign keys already
/// disabled (GRDB takes the `.immediate` branch in that case).
///
/// `playEvent` and `playSegmentHeat` carry a **bare** `trackId` with no foreign
/// key at all — by design, so listening history survives a deleted track. They
/// are unaffected by the rebuild for exactly that reason.
extension AppDatabase {
    /// Every `track` column that exists at v19, in physical order.
    ///
    /// One definition feeds both halves of the `INSERT … SELECT`, so the two
    /// lists cannot drift apart. The order matches the v1 `CREATE TABLE`
    /// followed by the `ALTER TABLE … ADD COLUMN`s of v5, v6, v7, v8 and v11 —
    /// which is what keeps a `SELECT *` on the rebuilt table byte-identical up
    /// to the four appended cue columns.
    ///
    /// The four columns v12 froze (`playCount`, `listenedCount`, `isFavourite`,
    /// `customPosition`) appear here, and ONLY here, because a rebuild that
    /// dropped them would destroy the v12 backfill's own source data. This is a
    /// carry-forward, not a read: nothing interprets the values.
    private static let v19TrackColumns = """
    id, filePath, title, sortTitle, artistName, albumTitle,
    artistId, albumId, trackNumber, discNumber, duration, bitrate,
    sampleRate, bitDepth, fileSize, mtime, availability, dateAdded,
    playCount, replaygainTrackGain, replaygainTrackPeak,
    replaygainAlbumGain, replaygainAlbumPeak, genre, albumArtist,
    composer, year, channelCount, customPosition, isFavourite,
    listenedCount
    """

    /// The whole v20 rebuild, in the order SQLite's 12-step recipe prescribes.
    ///
    /// The FTS5 index is dropped **first**, on purpose. `trackSearch` is an
    /// external-content index over `track`, and `synchronize(withTable:)` is what
    /// installed its `AFTER INSERT/UPDATE/DELETE` triggers — which live on
    /// `track`, so `DROP TABLE track` **will** take them with it. Dropping
    /// `trackSearch` up front means no FTS5 virtual table is ever pointing at a
    /// table that does not exist while the rename reparses the schema.
    ///
    /// It is then re-created through the very same ``createTrackSearchTable(_:)``
    /// the frozen `"v2"` block calls, so the index configuration cannot drift and
    /// the triggers are regenerated by GRDB rather than hand-written. That call
    /// also runs FTS5's `'rebuild'`, repopulating the index from the carried-over
    /// rows. A bare `INSERT INTO trackSearch(trackSearch) VALUES('rebuild')`
    /// would repopulate the index but leave it trigger-less — searchable today,
    /// silently stale from the next scan onwards.
    static func rebuildTrackForCueSupport(_ db: Database) throws {
        try db.execute(sql: "DROP TABLE trackSearch")
        try createCueAwareTrackTable(db)
        try copyTrackRowsIntoCueAwareTable(db)
        try db.execute(sql: "DROP TABLE track")
        try db.execute(sql: "ALTER TABLE track_new RENAME TO track")
        try recreateTrackIndexes(db)
        try addPerformanceIndexes(db)
        try createTrackSearchTable(db)
        try db.checkForeignKeys()
    }

    /// `track_new`: every v19 column verbatim, plus the four cue columns, with
    /// the v1 column-level `UNIQUE` on `filePath` replaced by a table-level
    /// `UNIQUE(filePath, cueStartFrame)`.
    static func createCueAwareTrackTable(_ db: Database) throws {
        try db.create(table: "track_new") { table in
            table.primaryKey("id", .integer)
            table.column("filePath", .text).notNull()
            table.column("title", .text)
            table.column("sortTitle", .text)
            table.column("artistName", .text)
            table.column("albumTitle", .text)
            table.column("artistId", .integer).references("artist", onDelete: .setNull)
            table.column("albumId", .integer).references("album", onDelete: .setNull)
            table.column("trackNumber", .integer)
            table.column("discNumber", .integer)
            table.column("duration", .double)
            table.column("bitrate", .integer)
            table.column("sampleRate", .integer)
            table.column("bitDepth", .integer)
            table.column("fileSize", .integer)
            table.column("mtime", .double)
            table.column("availability", .text)
                .notNull()
                .defaults(to: Availability.present.rawValue)
                .check(sql: "availability IN ('present', 'missing', 'externalOffline')")
            table.column("dateAdded", .double)
            table.column("playCount", .integer).notNull().defaults(to: 0)
            table.column("replaygainTrackGain", .double)
            table.column("replaygainTrackPeak", .double)
            table.column("replaygainAlbumGain", .double)
            table.column("replaygainAlbumPeak", .double)
            table.column("genre", .text)
            table.column("albumArtist", .text)
            table.column("composer", .text)
            table.column("year", .integer)
            table.column("channelCount", .integer)
            table.column("customPosition", .integer)
            table.column("isFavourite", .integer).notNull().defaults(to: 0)
            table.column("listenedCount", .integer).notNull().defaults(to: 0)
            table.column("cueSheetPath", .text)
            table.column("cueStartFrame", .integer).notNull().defaults(to: -1)
            table.column("cueEndFrame", .integer)
            table.column("cueSuppressed", .integer).notNull().defaults(to: 0)
            table.uniqueKey(["filePath", "cueStartFrame"])
        }
    }

    /// Copies every row across **with its rowid**.
    ///
    /// `id` is named explicitly on both sides: `profileTrackState`,
    /// `folderTrackOrder`, `trackAudioFeature`, `trackLoudness`, `playlistTrack`
    /// and the bare-`trackId` stats tables all key on `track.id`, so letting
    /// SQLite mint fresh rowids would orphan every one of them. The four new cue
    /// columns are absent from the insert list and therefore take their column
    /// defaults — `NULL / -1 / NULL / 0`, i.e. "an ordinary whole-file track".
    static func copyTrackRowsIntoCueAwareTable(_ db: Database) throws {
        try db.execute(sql: """
        INSERT INTO track_new (\(v19TrackColumns))
        SELECT \(v19TrackColumns) FROM track
        """)
    }

    /// The four v1 indexes. `DROP TABLE track` took them with it, and the rename
    /// does not bring them back — SQLite carries an index with the table it was
    /// declared on, and these were declared on the table that is now gone.
    ///
    /// The three v10 covering indexes are restored by calling the frozen
    /// ``addPerformanceIndexes(_:)`` itself (it is `CREATE INDEX IF NOT EXISTS`,
    /// so it is safe to re-run), which keeps their `COLLATE NOCASE` spelling in
    /// exactly one place.
    static func recreateTrackIndexes(_ db: Database) throws {
        try db.create(index: "track_on_artistId", on: "track", columns: ["artistId"])
        try db.create(index: "track_on_albumId", on: "track", columns: ["albumId"])
        try db.create(index: "track_on_availability", on: "track", columns: ["availability"])
        try db.create(index: "track_on_dateAdded", on: "track", columns: ["dateAdded"])
    }
}
