import Foundation
import GRDB

extension AppDatabase {
    /// The canonical schema migrator. Append-only: shipped migration strings are
    /// never edited. Never sets `eraseDatabaseOnSchemaChange` — that DEBUG-only
    /// convenience lives solely in the on-disk `makeShared()` path, so tests and
    /// production share one non-destructive migration code path.
    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try createArtistTable(db)
            try createAlbumTable(db)
            try createTrackTable(db)
            try createPlaylistTables(db)
            try createSmartPlaylistTable(db)
            try createArtworkRefTable(db)
            try createBookmarkTable(db)
        }

        // Append-only: "v1" is frozen; the FTS5 index ships as a new migration.
        migrator.registerMigration("v2") { db in
            try createTrackSearchTable(db)
        }

        // Append-only: "v1"/"v2" are frozen; custom EQ presets ship as a new migration.
        migrator.registerMigration("v3") { db in
            try createEQPresetTable(db)
        }

        // Append-only: "v1"/"v2"/"v3" are frozen; the lyrics cache ships as a new migration.
        migrator.registerMigration("v4") { db in
            try createLyricsCacheTable(db)
        }

        // Append-only: "v1"–"v4" are frozen; the nullable `genre` column ships as a
        // new migration. Filter-only — deliberately NOT added to the v2 FTS5
        // `trackSearch` index. Existing rows keep `genre IS NULL` until re-scanned.
        migrator.registerMigration("v5") { db in
            try db.alter(table: "track") { table in
                table.add(column: "genre", .text)
            }
        }

        // Append-only: "v1"–"v5" are frozen. v6 adds four nullable file-derived
        // columns (albumArtist, composer, year, channelCount), then backfills the
        // normalised artist/album graph and the track.artistId/albumId foreign keys
        // from the denormalised artistName/albumTitle text — entirely set-based SQL.
        migrator.registerMigration("v6") { db in
            try addExtendedTrackColumns(db)
            try backfillArtistAlbumGraph(db)
        }

        migrator.registerMigration("v7") { db in
            try db.alter(table: "track") { table in
                table.add(column: "customPosition", .integer)
            }
        }

        // Append-only: "v1"–"v7" are frozen. v8 adds the user "favourite" flag as a
        // boolean column (SQLite stores it as INTEGER 0/1). NOT NULL with a DEFAULT
        // so every existing row becomes a non-favourite without a backfill pass.
        migrator.registerMigration("v8") { db in
            try db.alter(table: "track") { table in
                table.add(column: "isFavourite", .integer).notNull().defaults(to: 0)
            }
        }

        // Append-only: "v1"–"v8" are frozen. v9 adds the online-info cache: one row
        // per (entityType, entityKey) holding the JSON-encoded ArtistInfo/AlbumInfo/
        // TrackInfo narrative fetched from MusicBrainz + Wikipedia, with a fetch
        // timestamp the store uses to expire stale entries.
        migrator.registerMigration("v9") { db in
            try createInfoCacheTable(db)
        }

        // Append-only: "v1"–"v9" are frozen. v10 adds covering indexes for the
        // hot filter/sort paths that lacked one at a 1000+ track scale: the
        // favourites view (isFavourite + customPosition), genre filtering
        // (case-insensitive equality / distinct), and per-folder browsing
        // (case-insensitive filePath prefix + customPosition). No schema change.
        migrator.registerMigration("v10") { db in
            try addPerformanceIndexes(db)
        }

        migrator.registerMigration("v11") { db in
            try db.alter(table: "track") { table in
                table.add(column: "listenedCount", .integer).notNull().defaults(to: 0)
            }
        }

        // Append-only: "v1"–"v11" are frozen. v12 adds the user-profiles tables
        // (`profile` + Guest row, `profileTrackState`, `libraryRoot`) and a nullable
        // `playlist.profileId`, backfills playlists + a SPARSE Guest track-state copy
        // from the now-frozen `track` columns, and never touches them again. Helpers:
        // `AppDatabase+Migrations+Profiles.swift`.
        migrator.registerMigration("v12") { db in
            try createProfileTable(db)
            try createProfileTrackStateTable(db)
            try createLibraryRootTable(db)
            try addPlaylistProfileColumn(db)
            try backfillGuestProfileState(db)
        }

        // v13: optional custom profile avatar image. NULL ⇒ render the `avatarId`
        // preset; when set, it is an absolute path to a downsampled PNG the shell
        // copied into Application Support. Additive, no backfill (existing rows keep
        // NULL and keep their preset).
        migrator.registerMigration("v13") { db in
            try db.alter(table: "profile") { table in
                table.add(column: "avatarImagePath", .text)
            }
        }

        // v14: one opaque playback snapshot per profile. `sourceJson` is nullable
        // until a caller has a navigable PlaybackSource to persist. Deleting a
        // profile removes its playback state through the primary-key foreign key.
        migrator.registerMigration("v14") { db in
            try db.create(table: "profilePlaybackState") { table in
                table.primaryKey("profileId", .integer)
                    .references("profile", onDelete: .cascade)
                table.column("snapshotJson", .text).notNull()
                table.column("sourceJson", .text)
                table.column("savedAt", .real).notNull()
            }
        }

        // v15: the listening-statistics substrate. `playEvent` and `playSegmentHeat`
        // deliberately carry a bare, non-foreign-key `trackId` and denormalise the
        // metadata at capture, so deleting a track (or a whole library root) leaves
        // the history intact — only the profile cascades. `playEventRollup` keeps a
        // permanent monthly summary once raw events age out; `folderTrackOrder` holds
        // per-root manual ordering. Helpers: `AppDatabase+Migrations+Stats.swift`.
        migrator.registerMigration("v15") { db in
            try createPlayEventTable(db)
            try createPlayEventRollupTable(db)
            try createFolderTrackOrderTable(db)
            try createPlaySegmentHeatTable(db)
        }

        // v16: the on-device playlist-intelligence substrate. `trackAudioFeature`
        // caches derived analysis keyed by the track alone (cascading, and fingerprinted
        // by `(fileSize, mtime)` so a re-encode or a recycled rowid reads as stale);
        // `generatedPlaylist` records which generator produced a playlist and from which
        // spec; `smartPlaylist` gains a rules-schema version and an evaluation stamp.
        // Helpers: `AppDatabase+Migrations+AI.swift`.
        migrator.registerMigration("v16") { db in
            try createTrackAudioFeatureTable(db)
            try createGeneratedPlaylistTable(db)
            try addSmartPlaylistRuleColumns(db)
        }

        // v17: the download-history log. `downloadHistory` carries NO foreign keys at
        // all — the `playEvent` survivability rule applied to downloads, so an entry
        // outlives the file it names and the library row that file may never have
        // become. Its `id` is a caller-minted UUID string, and `filePath` is a plain
        // path (this app is not sandboxed; bookmarks are house-forbidden).
        // Helpers: `AppDatabase+Migrations+Downloads.swift`.
        migrator.registerMigration("v17") { db in
            try createDownloadHistoryTable(db)
        }

        // v18: the offline loudness cache. `trackLoudness` mirrors `trackAudioFeature`
        // — caller-keyed by a cascading `trackId`, versioned by `analysisVersion` — but
        // fingerprints on FOUR parts, `(fileSize, mtime, cueStartFrame, cueEndFrame)`,
        // so a cue segment whose boundaries moved reads as stale even though the audio
        // file's bytes did not change. `integratedLUFS` is nullable because "no block
        // cleared the −70 LKFS gate" is a real answer; `blockPowersHistogram` holds the
        // fixed-size block-loudness histogram album pooling adds elementwise.
        // Helpers: `AppDatabase+Migrations+Loudness.swift`.
        migrator.registerMigration("v18") { db in
            try createTrackLoudnessTable(db)
        }

        // v19: custom parametric-EQ presets. A SECOND table, never extra columns on the
        // v3 `eqPreset` table — that one's `bandGainsJson` is contractually exactly 10
        // graphic-EQ gains, while a parametric bank has a variable filter count and a
        // different per-filter shape. `filtersJson` holds a JSON array of the
        // `AudioEngine` `ParametricFilter` values and stays opaque to `Persistence`,
        // which must not import `AudioEngine`.
        // Helpers: `AppDatabase+Migrations+ParametricEQ.swift`.
        migrator.registerMigration("v19") { db in
            try createParametricEQPresetTable(db)
        }

        // v20: the guarded `track` rebuild that enables CUE virtual tracks. The
        // v1 `filePath` UNIQUE is a COLUMN constraint (see `createTrackTable`
        // below) and SQLite cannot drop one, so replacing it with the
        // two-column `UNIQUE(filePath, cueStartFrame)` a cue library needs
        // requires the full 12-step rebuild — new table, rowid-preserving
        // INSERT-SELECT, drop, rename, re-index, FTS5 re-create,
        // `PRAGMA foreign_key_check`.
        //
        // The DEFAULT `foreignKeyChecks: .deferred` is load-bearing and must
        // never become `.immediate`: with foreign keys live, `DROP TABLE track`
        // would cascade through `playlistTrack`, `trackAudioFeature`,
        // `profileTrackState`, `folderTrackOrder` and `trackLoudness`.
        // Helpers: `AppDatabase+Migrations+CueTrack.swift`.
        migrator.registerMigration("v20") { db in
            try rebuildTrackForCueSupport(db)
        }

        migrator.registerMigration("v21") { db in
            try db.alter(table: "downloadHistory") { table in
                table.add(column: "failureReason", .text)
            }
        }

        return migrator
    }

    private static func createArtistTable(_ db: Database) throws {
        try db.create(table: "artist") { table in
            table.primaryKey("id", .integer)
            table.column("name", .text)
            table.column("sortName", .text).notNull()
            table.column("mbid", .text)
        }
        try db.create(index: "artist_on_sortName", on: "artist", columns: ["sortName"])
    }

    private static func createAlbumTable(_ db: Database) throws {
        try db.create(table: "album") { table in
            table.primaryKey("id", .integer)
            table.column("title", .text)
            table.column("sortTitle", .text)
            table.column("artistId", .integer).references("artist", onDelete: .setNull)
            table.column("year", .integer)
            table.column("mbid", .text)
        }
        try db.create(
            index: "album_on_artistId_sortTitle",
            on: "album",
            columns: ["artistId", "sortTitle"]
        )
    }

    private static func createTrackTable(_ db: Database) throws {
        try db.create(table: "track") { table in
            table.primaryKey("id", .integer)
            table.column("filePath", .text).notNull().unique()
            table.column("title", .text)
            table.column("sortTitle", .text)
            // Denormalised from artist/album so the v2 FTS5 external-content index
            // (Task 12) can be backed by the track table alone.
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
        }
        try db.create(index: "track_on_artistId", on: "track", columns: ["artistId"])
        try db.create(index: "track_on_albumId", on: "track", columns: ["albumId"])
        try db.create(index: "track_on_availability", on: "track", columns: ["availability"])
        try db.create(index: "track_on_dateAdded", on: "track", columns: ["dateAdded"])
    }

    private static func createPlaylistTables(_ db: Database) throws {
        try db.create(table: "playlist") { table in
            table.primaryKey("id", .integer)
            table.column("name", .text).notNull()
            table.column("isSmartPlaylist", .integer).notNull().defaults(to: 0)
        }
        try db.create(table: "playlistTrack") { table in
            table.primaryKey("id", .integer)
            table.column("playlistId", .integer).notNull().references("playlist", onDelete: .cascade)
            table.column("trackId", .integer).notNull().references("track", onDelete: .cascade)
            table.column("position", .integer).notNull()
            // Unique index also serves (playlistId, position) ordered reads.
            table.uniqueKey(["playlistId", "position"])
        }
        try db.create(index: "playlistTrack_on_trackId", on: "playlistTrack", columns: ["trackId"])
    }

    private static func createSmartPlaylistTable(_ db: Database) throws {
        try db.create(table: "smartPlaylist") { table in
            table.primaryKey("id", .integer)
            table.column("playlistId", .integer)
                .notNull()
                .unique()
                .references("playlist", onDelete: .cascade)
            table.column("rulesJson", .text).notNull()
        }
    }

    private static func createArtworkRefTable(_ db: Database) throws {
        try db.create(table: "artworkRef") { table in
            table.primaryKey("id", .integer)
            table.column("contentHash", .text).notNull().unique()
            table.column("diskPath", .text).notNull()
            table.column("width", .integer)
            table.column("height", .integer)
        }
    }

    private static func createBookmarkTable(_ db: Database) throws {
        try db.create(table: "bookmark") { table in
            table.primaryKey("id", .integer)
            table.column("scope", .text).notNull()
            table.column("bookmarkData", .blob).notNull()
            table.column("resolvedPath", .text)
        }
    }

    private static func createEQPresetTable(_ db: Database) throws {
        try db.create(table: "eqPreset") { table in
            table.primaryKey("id", .integer)
            table.column("name", .text).notNull().unique()
            table.column("bandGainsJson", .text).notNull()
            table.column("preamp", .real)
        }
    }

    private static func createLyricsCacheTable(_ db: Database) throws {
        try db.create(table: "lyricsCache") { table in
            table.primaryKey("id", .integer)
            table.column("cacheKey", .text).notNull().unique()
            table.column("source", .text).notNull()
            table.column("payloadJson", .text).notNull()
            table.column("fetchedAt", .double)
        }
    }

    private static func createInfoCacheTable(_ db: Database) throws {
        try db.create(table: "infoCache") { table in
            table.primaryKey("id", .integer)
            table.column("entityType", .text).notNull()
            table.column("entityKey", .text).notNull()
            table.column("infoJson", .text).notNull()
            table.column("fetchedAt", .double)
            table.uniqueKey(["entityType", "entityKey"])
        }
    }

    /// The `trackSearch` FTS5 full-text index over `track`.
    ///
    /// `synchronize(withTable:)` makes this an *external-content* index: only the
    /// inverted index is stored (`content='track'`, `content_rowid='id'`), never a
    /// second copy of the text. It also installs `AFTER INSERT/UPDATE/DELETE`
    /// triggers that keep the index in lock-step with `track`, and runs an initial
    /// `'rebuild'` so rows already present (e.g. in a forward-migrated v1 database)
    /// are indexed. `unicode61` with `remove_diacritics` folds accents, so
    /// "Bohème" is found by the query "boheme".
    static func createTrackSearchTable(_ db: Database) throws {
        try db.create(virtualTable: "trackSearch", using: FTS5()) { table in
            table.synchronize(withTable: "track")
            table.tokenizer = .unicode61(diacritics: .remove)
            table.column("title")
            table.column("artistName")
            table.column("albumTitle")
        }
    }
}
