import Foundation
import GRDB

/// v18 schema helpers — the offline loudness / ReplayGain analysis cache.
///
/// Split out of the base migrations file so it stays within the file-length budget,
/// mirroring `AppDatabase+Migrations+Profiles.swift`,
/// `AppDatabase+Migrations+Stats.swift`, `AppDatabase+Migrations+AI.swift` and
/// `AppDatabase+Migrations+Downloads.swift`. These are `internal static` only because
/// the `migrator` that invokes them lives in the sibling file; they stay scoped to
/// `Persistence` and are called exclusively from the frozen `"v18"` block.
extension AppDatabase {
    /// Cached BS.1770-4 loudness for one track — integrated LUFS, true peak, the
    /// album figures once its group pooled, and the block-loudness histogram that
    /// pooling is computed from.
    ///
    /// The primary key is the caller-supplied `trackId`; there is **no** auto-increment
    /// `id` column. That is the caller-keyed property of `profileTrackState` (whose own
    /// key is the composite `(profileId, trackId)`) applied to a single column, exactly
    /// as `profilePlaybackState` and `trackAudioFeature` do.
    ///
    /// Like `trackAudioFeature` and unlike `playEvent`, these rows carry **no**
    /// survivability duty: loudness is derived from the file, so `trackId` is a real
    /// cascading foreign key and deleting a track discards its analysis.
    ///
    /// ### The fingerprint is four-part, not two
    ///
    /// `(fileSize, mtime, cueStartFrame, cueEndFrame)` together fingerprint what was
    /// analysed. `(fileSize, mtime)` alone is the `trackAudioFeature` fingerprint and
    /// detects a re-encode plus SQLite rowid reuse; the two cue columns extend it to
    /// the *segment* boundaries, so editing a `.cue` sheet — which moves a segment
    /// without touching the audio file's bytes — reads as stale rather than silently
    /// serving the previous segment's loudness.
    ///
    /// `cueStartFrame` is `NOT NULL DEFAULT -1`, the `-1` sentinel meaning
    /// "whole file / not a cue segment", matching the convention v20 will bring to
    /// `track`. `cueEndFrame` is nullable, `NULL` meaning "to end of file" — the same
    /// spelling `CueTrack.endFrame` already uses.
    ///
    /// ### `integratedLUFS` is nullable on purpose
    ///
    /// `nil` is a **real answer**, not a missing one: it means no 400 ms block cleared
    /// the −70 LKFS absolute gate (digital silence, a clip shorter than one block, or
    /// genuine programme below the gate). `LoudnessMeasurement.integratedLUFS` is
    /// `Double?` for the same reason, and substituting `0` would assert a reference
    /// level that does not exist. `truePeak` stays `NOT NULL` because a true peak is
    /// always computable — silence measures linear `0`.
    ///
    /// `albumLUFS`/`albumPeak` are nullable because they only exist once the whole
    /// album group has pooled; a partial group leaves both `NULL` rather than a
    /// half-computed figure.
    ///
    /// ### `blockPowersHistogram`
    ///
    /// A fixed-size 3004-byte blob: ``BlockLoudnessHistogram/binCount`` little-endian
    /// `UInt32` counts of absolute-gate-passing block loudnesses in 0.1 dB bins. It is
    /// nullable so a row can record a measurement whose blocks were not retained, but
    /// album pooling requires it on **every** member. See ``BlockLoudnessHistogram``
    /// for the bin mapping and why the representation is a histogram rather than the
    /// raw block set.
    ///
    /// No secondary index: every read path seeks `trackLoudness` by its rowid-alias
    /// primary key (the staleness anti-join, the batch histogram read for pooling, and
    /// the album write-back all key on `trackId`), so an index would only cost writes.
    static func createTrackLoudnessTable(_ db: Database) throws {
        try db.create(table: "trackLoudness") { table in
            table.primaryKey("trackId", .integer)
                .references("track", onDelete: .cascade)
            table.column("integratedLUFS", .double)
            table.column("truePeak", .double).notNull()
            table.column("albumLUFS", .double)
            table.column("albumPeak", .double)
            table.column("blockPowersHistogram", .blob)
            table.column("analysisVersion", .integer).notNull()
            table.column("fileSize", .integer).notNull()
            table.column("mtime", .double).notNull()
            table.column("cueStartFrame", .integer).notNull().defaults(to: -1)
            table.column("cueEndFrame", .integer)
            table.column("computedAt", .double).notNull()
        }
    }
}
