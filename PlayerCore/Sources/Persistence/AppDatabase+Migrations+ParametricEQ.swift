import Foundation
import GRDB

/// v19 schema helpers — custom parametric-EQ presets.
///
/// Split out of the base migrations file so it stays within the file-length budget,
/// mirroring `AppDatabase+Migrations+Profiles.swift`,
/// `AppDatabase+Migrations+Stats.swift`, `AppDatabase+Migrations+AI.swift`,
/// `AppDatabase+Migrations+Downloads.swift` and
/// `AppDatabase+Migrations+Loudness.swift`. These are `internal static` only because
/// the `migrator` that invokes them lives in the sibling file; they stay scoped to
/// `Persistence` and are called exclusively from the frozen `"v19"` block.
extension AppDatabase {
    /// Custom parametric-EQ presets — an AutoEq-style filter bank plus a pre-amp trim.
    ///
    /// Deliberately a **second, separate table** rather than extra columns on the v3
    /// `eqPreset` table. `eqPreset` is the 10-band graphic EQ's store and its
    /// `bandGainsJson` carries a fixed-length array of exactly 10 gains — a contract
    /// `EQPresetRecord.toPreset()` enforces on every read. A parametric bank has a
    /// variable filter count and a different per-filter shape, so folding the two
    /// together would mean one of the two reads has to guess which kind of preset a
    /// row holds. Two tables means neither ever has to.
    ///
    /// ### Columns
    ///
    /// - `id` — rowid alias, the house convention for a store-owned key.
    /// - `name` — `NOT NULL UNIQUE`, matching `eqPreset`. Uniqueness is what makes a
    ///   same-name `save` an upsert rather than a silent duplicate, and it is enforced
    ///   by the database rather than only by the store.
    /// - `filtersJson` — `NOT NULL`. A JSON **array** of the `AudioEngine`
    ///   `ParametricFilter` values, in profile order.
    /// - `preamp` — nullable `REAL`, in dB. `NULL` means "no trim recorded", exactly as
    ///   on `eqPreset`; it is *not* the same as a stored `0`, which is an explicit
    ///   "measured, and it is unity".
    ///
    /// ### Why `filtersJson` is opaque to `Persistence`
    ///
    /// `ParametricFilter` lives in `AudioEngine`, which `Persistence` must not import
    /// (it would drag `AVFAudio` and `SFBAudioEngine` behind it). The same discipline
    /// that keeps `BlockLoudnessHistogram` taking `[Double]` instead of a
    /// `Services.LoudnessMeasurement` applies here: the column is text this module
    /// stores and returns verbatim, and the typed decode is the caller's step through
    /// ``ParametricEQPreset/filters(as:)``. A row whose JSON cannot be decoded is
    /// therefore a *caller-visible* failure, not one that can poison a whole
    /// `loadAll()`.
    ///
    /// No secondary index: reads are either the whole (tiny, user-authored) table
    /// ordered by `name`, or a single `name` lookup the `UNIQUE` constraint's own
    /// index already covers.
    static func createParametricEQPresetTable(_ db: Database) throws {
        try db.create(table: "parametricEQPreset") { table in
            table.primaryKey("id", .integer)
            table.column("name", .text).notNull().unique()
            table.column("filtersJson", .text).notNull()
            table.column("preamp", .real)
        }
    }
}
