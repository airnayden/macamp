import Foundation
import GRDB

/// v16 schema helpers — the on-device playlist-intelligence substrate.
///
/// Split out of the base migrations file so it stays within the file-length budget,
/// mirroring `AppDatabase+Migrations+Profiles.swift` and
/// `AppDatabase+Migrations+Stats.swift`. These are `internal static` only because the
/// `migrator` that invokes them lives in the sibling file; they stay scoped to
/// `Persistence` and are called exclusively from the frozen `"v16"` block.
extension AppDatabase {
    /// Cached audio analysis for one track — tempo, energy and spectral brightness.
    ///
    /// The primary key is the caller-supplied `trackId`; there is **no** auto-increment
    /// `id` column. That is the caller-keyed property of `profileTrackState` (whose own
    /// key is the composite `(profileId, trackId)`) applied to a single column, exactly
    /// as `profilePlaybackState` does with `profileId`.
    ///
    /// Unlike `playEvent`/`playSegmentHeat`, these rows carry **no** survivability duty:
    /// features are derived from the file, so `trackId` is a real cascading foreign key
    /// and deleting a track discards its analysis. `fileSize`/`mtime` fingerprint the
    /// bytes that were analysed, which both detects a re-encode and defuses SQLite rowid
    /// reuse — a recycled `trackId` reads as stale rather than silently serving another
    /// track's features.
    ///
    /// `bpm` is the only nullable measure: tempo estimation legitimately finds no
    /// reliable beat in ambient or non-percussive material, whereas energy and
    /// brightness are always computable. The `energy`/`bpm` indexes back the range
    /// predicates the smart-playlist compiler and the mix generator emit.
    static func createTrackAudioFeatureTable(_ db: Database) throws {
        try db.create(table: "trackAudioFeature") { table in
            table.primaryKey("trackId", .integer)
                .references("track", onDelete: .cascade)
            table.column("fileSize", .integer).notNull()
            table.column("mtime", .double).notNull()
            table.column("bpm", .double)
            table.column("energy", .double).notNull()
            table.column("brightness", .double).notNull()
            table.column("analysisVersion", .integer).notNull()
            table.column("computedAt", .double).notNull()
        }
        try db.create(
            index: "trackAudioFeature_on_energy",
            on: "trackAudioFeature",
            columns: ["energy"]
        )
        try db.create(
            index: "trackAudioFeature_on_bpm",
            on: "trackAudioFeature",
            columns: ["bpm"]
        )
    }

    /// Provenance for a playlist a generator produced: which generator, from which
    /// spec, and when it last refreshed.
    ///
    /// Shaped exactly like `smartPlaylist` — an auto-increment `id` plus a `UNIQUE`
    /// cascading `playlistId`, so at most one row exists per playlist and deleting the
    /// playlist drops it. `specJson` is opaque to Persistence; the owning service
    /// versions it through `specVersion`. `lastRefreshedAt` stays NULL until the first
    /// refresh. The `generatorKind` index backs "show me every daypart mix" reads.
    static func createGeneratedPlaylistTable(_ db: Database) throws {
        try db.create(table: "generatedPlaylist") { table in
            table.primaryKey("id", .integer)
            table.column("playlistId", .integer)
                .notNull()
                .unique()
                .references("playlist", onDelete: .cascade)
            table.column("generatorKind", .text).notNull()
            table.column("specJson", .text).notNull()
            table.column("specVersion", .integer).notNull()
            table.column("lastRefreshedAt", .double)
        }
        try db.create(
            index: "generatedPlaylist_on_generatorKind",
            on: "generatedPlaylist",
            columns: ["generatorKind"]
        )
    }

    /// Versions the smart-playlist rule schema and records when rules last evaluated.
    ///
    /// `rulesVersion` carries no foreign key, so unlike v12's `playlist.profileId` it
    /// can be added `NOT NULL DEFAULT 1` in a single `ALTER TABLE` — SQLite applies the
    /// default to every existing row, which is precisely the "rules predating versioning
    /// are schema v1" backfill. `lastEvaluatedAt` is nullable: NULL means "never
    /// evaluated", which is what every pre-v16 row is.
    static func addSmartPlaylistRuleColumns(_ db: Database) throws {
        try db.alter(table: "smartPlaylist") { table in
            table.add(column: "rulesVersion", .integer).notNull().defaults(to: 1)
            table.add(column: "lastEvaluatedAt", .double)
        }
    }
}
