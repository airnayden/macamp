import Foundation
import GRDB

/// v12 schema helpers — the user-profiles feature.
///
/// Split out of the base migrations file so it stays within the file-length
/// budget. These are `internal static` (not `private`) only because the `migrator`
/// that invokes them lives in the sibling file; they stay scoped to `Persistence`
/// and are called exclusively from the frozen `"v12"` migration block.
extension AppDatabase {
    /// The `profile` table plus the built-in Guest row (id 1). The UI localises the
    /// display name for id 1, so the stored `name` is only the plain fallback
    /// "Guest". `avatarId` defaults to the shipped `waveform-vice` preset; the PIN
    /// columns stay NULL until a profile opts into a PIN.
    static func createProfileTable(_ db: Database) throws {
        try db.create(table: "profile") { table in
            table.primaryKey("id", .integer)
            table.column("name", .text).notNull()
            table.column("lastName", .text)
            table.column("bio", .text)
            table.column("avatarId", .text).notNull().defaults(to: "waveform-vice")
            table.column("pinHash", .text)
            table.column("pinSalt", .text)
            table.column("createdAt", .datetime).notNull()
        }
        try db.execute(sql: "INSERT INTO profile (id, name, createdAt) VALUES (1, 'Guest', datetime('now'))")
    }

    /// Per-profile track state (favourite, counts, custom order), keyed by
    /// `(profileId, trackId)`. Rows are SPARSE — one appears only once a profile
    /// actually favourites, plays or reorders a track. Both foreign keys cascade, so
    /// deleting a profile (or a track) drops its state. The
    /// `(profileId, isFavourite, customPosition)` index covers the favourites view.
    static func createProfileTrackStateTable(_ db: Database) throws {
        try db.create(table: "profileTrackState") { table in
            table.column("profileId", .integer)
                .notNull()
                .references("profile", onDelete: .cascade)
            table.column("trackId", .integer)
                .notNull()
                .references("track", onDelete: .cascade)
            table.column("isFavourite", .integer).notNull().defaults(to: 0)
            table.column("playCount", .integer).notNull().defaults(to: 0)
            table.column("listenedCount", .integer).notNull().defaults(to: 0)
            table.column("customPosition", .integer)
            table.primaryKey(["profileId", "trackId"])
        }
        try db.create(
            index: "profileTrackState_on_profileId_isFavourite_customPosition",
            on: "profileTrackState",
            columns: ["profileId", "isFavourite", "customPosition"]
        )
    }

    /// Per-profile library roots. A profile sees tracks under its own roots (plus
    /// ownerless tracks); roots migrate here from UserDefaults in a later task, so
    /// the table is created empty. `UNIQUE(profileId, path)` blocks a duplicate root.
    static func createLibraryRootTable(_ db: Database) throws {
        try db.create(table: "libraryRoot") { table in
            table.primaryKey("id", .integer)
            table.column("profileId", .integer)
                .notNull()
                .references("profile", onDelete: .cascade)
            table.column("path", .text).notNull()
            table.uniqueKey(["profileId", "path"])
        }
    }

    /// Scopes playlists by profile. SQLite forbids adding a NOT NULL column that
    /// carries a foreign key in one `ALTER TABLE`, so `profileId` is added nullable
    /// and every existing playlist is then backfilled to the Guest profile.
    static func addPlaylistProfileColumn(_ db: Database) throws {
        try db.alter(table: "playlist") { table in
            table.add(column: "profileId", .integer)
                .references("profile", onDelete: .cascade)
        }
        try db.execute(sql: "UPDATE playlist SET profileId = 1")
    }

    /// SPARSE backfill of Guest's per-track state: only tracks that actually carry
    /// state (favourited, played, listened, or manually positioned) get a row, so a
    /// fresh library adds none. Pure set-based SQL; the frozen `track` user-state
    /// columns are read here for the last time.
    static func backfillGuestProfileState(_ db: Database) throws {
        try db.execute(sql: """
        INSERT INTO profileTrackState
            (profileId, trackId, isFavourite, playCount, listenedCount, customPosition)
        SELECT 1, id, isFavourite, playCount, listenedCount, customPosition
        FROM track
        WHERE isFavourite = 1
           OR playCount > 0
           OR listenedCount > 0
           OR customPosition IS NOT NULL
        """)
    }
}
