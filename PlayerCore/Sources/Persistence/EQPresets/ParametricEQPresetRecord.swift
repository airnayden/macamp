import Foundation
import GRDB

// ParametricEQPresetRecord — GRDB-backed persistence record for the v19
// `parametricEQPreset` table.
//
// The graphic-EQ sibling `EQPresetRecord` / `eqPreset` (v3) is a separate table with
// a separate contract and is untouched by this type.
//
// Schema (created in migration "v19"):
//   id          INTEGER PRIMARY KEY
//   name        TEXT NOT NULL UNIQUE
//   filtersJson TEXT NOT NULL   -- JSON array of AudioEngine.ParametricFilter
//   preamp      REAL            -- nullable global pre-amp trim (dB)

/// A GRDB record mapping a custom parametric-EQ preset to the `parametricEQPreset` table.
struct ParametricEQPresetRecord: Codable, Equatable {
    /// Auto-incremented rowid primary key. `nil` until inserted.
    var id: Int64?
    /// Display name. `UNIQUE NOT NULL`.
    var name: String
    /// JSON-encoded array of `AudioEngine.ParametricFilter` values.
    var filtersJson: String
    /// Optional global pre-amp trim in dB.
    var preamp: Double?
}

extension ParametricEQPresetRecord: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "parametricEQPreset"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let name = Column(CodingKeys.name)
        static let filtersJson = Column(CodingKeys.filtersJson)
        static let preamp = Column(CodingKeys.preamp)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Conversion helpers

extension ParametricEQPresetRecord {
    init(preset: ParametricEQPreset) {
        id = nil
        name = preset.name
        filtersJson = preset.filtersJson
        preamp = preset.preamp
    }

    /// Converts this record back to a domain ``ParametricEQPreset``.
    ///
    /// Non-throwing on purpose, in deliberate contrast to `EQPresetRecord.toPreset()`,
    /// which validates its 10-gain contract and throws. `filtersJson` is carried across
    /// verbatim and never decoded here, so a row holding unreadable JSON still loads and
    /// fails only when its owner asks for typed filters
    /// (``ParametricEQPreset/filters(as:)``). That is what keeps one bad row from
    /// emptying the whole preset list.
    func toPreset() -> ParametricEQPreset {
        ParametricEQPreset(name: name, filtersJson: filtersJson, preamp: preamp)
    }
}
