import Foundation
import GRDB

/// v6 and v10 schema helpers — the track table's column and index evolution.
///
/// Split out of the base migrations file so it stays within the file-length budget,
/// mirroring `AppDatabase+Migrations+Profiles.swift`,
/// `AppDatabase+Migrations+Stats.swift`, `AppDatabase+Migrations+AI.swift`,
/// `AppDatabase+Migrations+Downloads.swift` and
/// `AppDatabase+Migrations+Loudness.swift`.
///
/// Moved here with **no change to what they do**. Two things did change, neither
/// semantic: the access level went from file-scoped `private` to module-scoped
/// `static` (what the other split helpers already use, so the `migrator` in the
/// sibling file can still call them), and SwiftFormat re-indented the multiline SQL
/// literals. The latter shifts a literal's body and its closing `"""` by the same
/// amount, and Swift strips exactly the closing delimiter's indentation from every
/// line — so all eight SQL strings are byte-identical to the ones that shipped,
/// which was verified rather than assumed.
///
/// They stay scoped to `Persistence` and are called exclusively from the frozen
/// `"v6"` and `"v10"` blocks, which are untouched.
extension AppDatabase {
    /// v10: covering indexes for the favourites, genre and folder query paths.
    ///
    /// `genre`/`filePath` are indexed `COLLATE NOCASE` so the case-insensitive
    /// `genre = ?`/`filePath LIKE 'root/%'` predicates can seek the index instead
    /// of scanning the table — raw SQL is used because the GRDB index DSL cannot
    /// express a per-column collation.
    static func addPerformanceIndexes(_ db: Database) throws {
        try db.execute(sql: """
        CREATE INDEX IF NOT EXISTS track_on_isFavourite_customPosition
        ON track(isFavourite, customPosition)
        """)
        try db.execute(sql: """
        CREATE INDEX IF NOT EXISTS track_on_genre
        ON track(genre COLLATE NOCASE)
        """)
        try db.execute(sql: """
        CREATE INDEX IF NOT EXISTS track_on_filePath_customPosition
        ON track(filePath COLLATE NOCASE, customPosition)
        """)
    }

    static func addExtendedTrackColumns(_ db: Database) throws {
        try db.alter(table: "track") { table in
            table.add(column: "albumArtist", .text)
            table.add(column: "composer", .text)
            table.add(column: "year", .integer)
            table.add(column: "channelCount", .integer)
        }
    }

    /// v6 step 2: normalise the artist/album graph from the denormalised
    /// `artistName`/`albumTitle` text and wire up `track.artistId`/`albumId`.
    ///
    /// The uniqueness indexes are created FIRST, on purpose: a forward-migrated
    /// database (e.g. the committed v1 test fixture) already holds normalised
    /// artist/album rows. Without the index the subsequent `INSERT OR IGNORE`
    /// would find no constraint to violate and append a *duplicate* row, which
    /// would then make the very index creation fail. Index-first turns the
    /// backfill into a genuine, idempotent upsert that skips rows already present.
    static func backfillArtistAlbumGraph(_ db: Database) throws {
        try db.execute(sql: "CREATE UNIQUE INDEX IF NOT EXISTS artist_unique_name ON artist(name)")
        try db.execute(sql: """
        CREATE UNIQUE INDEX IF NOT EXISTS album_unique_title_artistId
        ON album(title, artistId)
        """)
        try db.execute(sql: """
        INSERT OR IGNORE INTO artist (name, sortName)
        SELECT DISTINCT artistName, artistName FROM track
        WHERE artistName IS NOT NULL AND artistName != ''
        """)
        try db.execute(sql: """
        INSERT OR IGNORE INTO album (title, sortTitle, artistId)
        SELECT DISTINCT t.albumTitle, t.albumTitle, a.id
        FROM track t JOIN artist a ON a.name = t.artistName
        WHERE t.albumTitle IS NOT NULL AND t.albumTitle != ''
        """)
        try db.execute(sql: """
        UPDATE track SET artistId = (
            SELECT id FROM artist WHERE name = track.artistName
        ) WHERE artistName IS NOT NULL
        """)
        try db.execute(sql: """
        UPDATE track SET albumId = (
            SELECT a.id FROM album a JOIN artist ar ON a.artistId = ar.id
            WHERE a.title = track.albumTitle AND ar.name = track.artistName
        ) WHERE albumTitle IS NOT NULL
        """)
    }
}
