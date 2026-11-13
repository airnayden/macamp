import Foundation
import GRDB

// EQPresetRecord — GRDB-backed persistence record for the `eqPreset` table.
//
// Only CUSTOM user presets are persisted. Built-in presets live as code
// constants in `EQPreset.builtIns` and are never written to the database.
//
// Schema (created in migration "v3"):
//   id           INTEGER PRIMARY KEY
//   name         TEXT NOT NULL UNIQUE
//   bandGainsJson TEXT NOT NULL   -- JSON array of 10 Float values
//   preamp       REAL             -- nullable global pre-amp trim (dB)

/// A GRDB record mapping a custom EQ preset to the `eqPreset` table.
struct EQPresetRecord: Codable, Equatable {
    /// Auto-incremented rowid primary key. `nil` until inserted.
    var id: Int64?
    /// Display name. `UNIQUE NOT NULL`.
    var name: String
    /// JSON-encoded array of 10 per-band gains (dB).
    var bandGainsJson: String
    /// Optional global pre-amp trim in dB.
    var preamp: Double?
}

extension EQPresetRecord: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "eqPreset"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let name = Column(CodingKeys.name)
        static let bandGainsJson = Column(CodingKeys.bandGainsJson)
        static let preamp = Column(CodingKeys.preamp)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Conversion helpers

extension EQPresetRecord {
    /// Converts a domain `EQPreset` into a storable record.
    ///
    /// - Parameter preset: The domain preset to encode.
    /// - Throws: `EncodingError` if the band gains cannot be JSON-encoded.
    init(preset: EQPreset) throws {
        let data = try JSONEncoder().encode(preset.bandGains)
        guard let json = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                preset.bandGains,
                .init(codingPath: [], debugDescription: "bandGains JSON encoding produced non-UTF8 data")
            )
        }
        id = nil
        name = preset.name
        bandGainsJson = json
        preamp = preset.preamp.map { Double($0) }
    }

    /// Converts this record back to a domain `EQPreset`.
    ///
    /// - Throws: `DecodingError` if `bandGainsJson` is malformed or does not
    ///   contain exactly 10 values.
    func toPreset() throws -> EQPreset {
        guard let data = bandGainsJson.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "bandGainsJson is not valid UTF-8")
            )
        }
        let gains = try JSONDecoder().decode([Float].self, from: data)
        guard gains.count == 10 else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: [],
                    debugDescription: "bandGainsJson must contain exactly 10 values, got \(gains.count)"
                )
            )
        }
        return EQPreset(
            name: name,
            bandGains: gains,
            preamp: preamp.map { Float($0) }
        )
    }
}
