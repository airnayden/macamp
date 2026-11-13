import Foundation
import GRDB

/// v17 schema helpers — the download-history log.
///
/// Split out of the base migrations file so it stays within the file-length budget,
/// mirroring `AppDatabase+Migrations+Profiles.swift`,
/// `AppDatabase+Migrations+Stats.swift` and `AppDatabase+Migrations+AI.swift`. These
/// are `internal static` only because the `migrator` that invokes them lives in the
/// sibling file; they stay scoped to `Persistence` and are called exclusively from
/// the frozen `"v17"` block.
extension AppDatabase {
    /// One row per finished download, denormalised at capture so the entry outlives
    /// everything it describes.
    ///
    /// **No foreign keys at all** — not to `track`, not to `profile`. That is the
    /// `playEvent` survivability precedent applied to downloads: a file the listener
    /// later moved, deleted, or never imported into the library must still show up in
    /// history, and the destination folder is a single global setting rather than a
    /// per-profile one. Every field needed to describe the download is snapshotted
    /// here, and nothing is joined at read time.
    ///
    /// ``id`` is a caller-minted UUID string rather than an auto-increment rowid, so
    /// the recorder can name an entry before it reaches the database. The table is
    /// still an ordinary rowid table (a TEXT primary key is not a rowid alias), and
    /// the keyset window in `DownloadHistoryRepository` tie-breaks on that implicit
    /// rowid — see the note there for why the TEXT key itself cannot be the
    /// tie-breaker.
    ///
    /// `filePath` is a **plain path**, never a security-scoped bookmark: MacAMP is
    /// direct-distribution and NOT sandboxed (`macOS/macampMac.entitlements`), and
    /// bookmarks are house-forbidden. The path is a record of where the file was
    /// written — history never opens, moves or deletes it.
    ///
    /// `audioFormat`/`audioQuality` hold the **raw values** of the two storage enums
    /// (`DownloadAudioFormat` / `DownloadAudioQuality`). They are stored as two TEXT
    /// columns rather than one because `DownloadFormat` is a composite whose only
    /// case carries both, and because those raw values are already a frozen wire
    /// format the settings layer persists. Those enums live in `Services`, which
    /// depends on `Persistence` and not the other way round, so this module stores
    /// the tokens and lets the caller map them.
    ///
    /// `utcOffsetSeconds` stores the capture-time offset east of GMT, exactly as
    /// `playEvent` does, so a row can be rendered as the wall-clock time it was
    /// actually downloaded at without consulting a `Calendar` at read time.
    static func createDownloadHistoryTable(_ db: Database) throws {
        try db.create(table: "downloadHistory") { table in
            table.primaryKey("id", .text)
            table.column("canonicalVideoID", .text).notNull()
            table.column("title", .text)
            table.column("uploader", .text)
            table.column("durationSeconds", .double)
            table.column("filePath", .text).notNull()
            table.column("audioFormat", .text).notNull()
            table.column("audioQuality", .text).notNull()
            table.column("sourceURL", .text).notNull()
            table.column("downloadedAt", .double).notNull()
            table.column("utcOffsetSeconds", .integer).notNull()
        }
        try db.create(
            index: "downloadHistory_on_canonicalVideoID",
            on: "downloadHistory",
            columns: ["canonicalVideoID"]
        )
        // Raw SQL for the same reason `addPerformanceIndexes` uses it: the GRDB index
        // DSL cannot express a per-column direction. The history list is read newest
        // first and only ever newest first, so the index is declared in that order.
        try db.execute(sql: """
        CREATE INDEX IF NOT EXISTS downloadHistory_on_downloadedAt
        ON downloadHistory(downloadedAt DESC)
        """)
    }
}
