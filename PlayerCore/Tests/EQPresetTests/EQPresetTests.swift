import Foundation
import GRDB
import Persistence
import Testing

@Suite("EQPresetTests", .serialized)
struct EQPresetTests {
    // MARK: - Built-in presets

    @Test("all 8 built-in presets are present")
    func builtInsCount() {
        #expect(EQPreset.builtIns.count == 8)
    }

    @Test("every built-in preset has exactly 10 band gains")
    func builtInsBandCount() {
        for preset in EQPreset.builtIns {
            #expect(preset.bandGains.count == 10, "preset '\(preset.name)' has \(preset.bandGains.count) bands")
        }
    }

    @Test("built-in preset names are unique")
    func builtInsNamesUnique() {
        let names = EQPreset.builtIns.map(\.name)
        #expect(Set(names).count == names.count)
    }

    @Test("flat preset has all zero gains")
    func flatPresetIsZero() {
        let flat = EQPreset.flat
        #expect(flat.bandGains.allSatisfy { $0 == 0 })
        #expect(flat.preamp == nil)
    }

    @Test("built-in presets include Flat, Rock, Pop, Jazz, Classical, Bass Boost, Vocal, Treble Boost")
    func builtInsNames() {
        let names = Set(EQPreset.builtIns.map(\.name))
        for expected in ["Flat", "Rock", "Pop", "Jazz", "Classical", "Bass Boost", "Vocal", "Treble Boost"] {
            #expect(names.contains(expected), "missing built-in '\(expected)'")
        }
    }

    // MARK: - bandGainValues helper

    @Test("bandGainValues returns the same array as bandGains")
    func bandGainValuesMatchesBandGains() {
        for preset in EQPreset.builtIns {
            #expect(preset.bandGainValues == preset.bandGains)
        }
    }

    @Test("applying flat preset yields 10 zero gains")
    func applyFlatPreset() {
        let gains = EQPreset.flat.bandGainValues
        #expect(gains.count == 10)
        #expect(gains.allSatisfy { $0 == 0 })
    }

    @Test("applying bass boost preset yields positive low-band gains")
    func applyBassBoostPreset() {
        let gains = EQPreset.bassBoost.bandGainValues
        #expect(gains.count == 10)
        #expect(gains[0] > 0, "32 Hz band should be boosted")
        #expect(gains[1] > 0, "64 Hz band should be boosted")
        #expect(gains[2] > 0, "125 Hz band should be boosted")
    }

    @Test("applying treble boost preset yields positive high-band gains")
    func applyTrebleBoostPreset() {
        let gains = EQPreset.trebleBoost.bandGainValues
        #expect(gains.count == 10)
        #expect(gains[8] > 0, "8k Hz band should be boosted")
        #expect(gains[9] > 0, "16k Hz band should be boosted")
    }

    @Test("applying rock preset yields scooped mids")
    func applyRockPreset() {
        let gains = EQPreset.rock.bandGainValues
        #expect(gains.count == 10)
        #expect(gains[5] < 0, "1k Hz mid band should be cut in rock preset")
    }

    // MARK: - Custom preset CRUD (in-memory DB)

    @Test("save and load a custom preset round-trips correctly")
    func saveLoadRoundTrip() throws {
        let appDB = try AppDatabase.makeEmpty()
        let store = GRDBEQPresetStore(appDB)
        let preset = EQPreset(
            name: "My Custom",
            bandGains: [1, 2, 3, 4, 5, -1, -2, -3, -4, -5],
            preamp: -1.5
        )
        try store.save(preset)
        let loaded = try store.loadAll()
        #expect(loaded.count == 1)
        let first = try #require(loaded.first)
        #expect(first.name == preset.name)
        #expect(first.bandGains == preset.bandGains)
        #expect(first.preamp == preset.preamp)
    }

    @Test("save with same name replaces existing preset (upsert)")
    func saveUpsert() throws {
        let appDB = try AppDatabase.makeEmpty()
        let store = GRDBEQPresetStore(appDB)
        let original = EQPreset(name: "Upsert Test", bandGains: [Float](repeating: 1, count: 10))
        try store.save(original)
        let updated = EQPreset(name: "Upsert Test", bandGains: [Float](repeating: 3, count: 10), preamp: 2)
        try store.save(updated)
        let loaded = try store.loadAll()
        #expect(loaded.count == 1)
        let first = try #require(loaded.first)
        #expect(first.bandGains == [Float](repeating: 3, count: 10))
        #expect(first.preamp == 2)
    }

    @Test("delete removes a custom preset by name")
    func deletePreset() throws {
        let appDB = try AppDatabase.makeEmpty()
        let store = GRDBEQPresetStore(appDB)
        let preset = EQPreset(name: "To Delete", bandGains: [Float](repeating: 0, count: 10))
        try store.save(preset)
        #expect(try store.loadAll().count == 1)
        try store.delete(named: "To Delete")
        #expect(try store.loadAll().isEmpty)
    }

    @Test("delete of non-existent name is a no-op")
    func deleteNonExistent() throws {
        let appDB = try AppDatabase.makeEmpty()
        let store = GRDBEQPresetStore(appDB)
        try store.delete(named: "Ghost Preset")
        #expect(try store.loadAll().isEmpty)
    }

    @Test("loadAll returns presets ordered by name")
    func loadAllOrdered() throws {
        let appDB = try AppDatabase.makeEmpty()
        let store = GRDBEQPresetStore(appDB)
        let names = ["Zebra", "Alpha", "Mango"]
        for name in names {
            try store.save(EQPreset(name: name, bandGains: [Float](repeating: 0, count: 10)))
        }
        let loaded = try store.loadAll()
        #expect(loaded.map(\.name) == ["Alpha", "Mango", "Zebra"])
    }

    @Test("preset with nil preamp round-trips correctly")
    func nilPreampRoundTrip() throws {
        let appDB = try AppDatabase.makeEmpty()
        let store = GRDBEQPresetStore(appDB)
        let preset = EQPreset(name: "No Preamp", bandGains: [Float](repeating: 0, count: 10), preamp: nil)
        try store.save(preset)
        let loaded = try #require(try store.loadAll().first)
        #expect(loaded.preamp == nil)
    }

    // MARK: - Import / Export JSON

    @Test("export then import JSON round-trips all custom presets")
    func importExportRoundTrip() throws {
        let appDB = try AppDatabase.makeEmpty()
        let store = GRDBEQPresetStore(appDB)
        let presets = [
            EQPreset(name: "Export A", bandGains: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]),
            EQPreset(name: "Export B", bandGains: [Float](repeating: -3, count: 10), preamp: -2),
        ]
        for preset in presets {
            try store.save(preset)
        }
        let jsonData = try store.exportJSON()
        #expect(!jsonData.isEmpty)

        let appDB2 = try AppDatabase.makeEmpty()
        let store2 = GRDBEQPresetStore(appDB2)
        try store2.importJSON(jsonData)
        let loaded = try store2.loadAll()
        #expect(loaded.count == 2)
        let names = Set(loaded.map(\.name))
        #expect(names.contains("Export A"))
        #expect(names.contains("Export B"))
    }

    @Test("exported JSON is valid and decodable as [EQPreset]")
    func exportedJSONIsDecodable() throws {
        let appDB = try AppDatabase.makeEmpty()
        let store = GRDBEQPresetStore(appDB)
        try store.save(EQPreset(name: "JSON Test", bandGains: [Float](repeating: 1.5, count: 10)))
        let data = try store.exportJSON()
        let decoded = try JSONDecoder().decode([EQPreset].self, from: data)
        #expect(decoded.count == 1)
        #expect(decoded.first?.name == "JSON Test")
    }

    @Test("import replaces existing preset with same name")
    func importReplacesExisting() throws {
        let appDB = try AppDatabase.makeEmpty()
        let store = GRDBEQPresetStore(appDB)
        try store.save(EQPreset(name: "Shared", bandGains: [Float](repeating: 1, count: 10)))
        let replacement = [EQPreset(name: "Shared", bandGains: [Float](repeating: 9, count: 10))]
        let data = try JSONEncoder().encode(replacement)
        try store.importJSON(data)
        let loaded = try store.loadAll()
        #expect(loaded.count == 1)
        #expect(loaded.first?.bandGains == [Float](repeating: 9, count: 10))
    }

    // MARK: - Migration

    @Test("makeEmpty() migrates to head including v3; eqPreset table exists")
    func migrationIncludesV3() throws {
        let appDB = try AppDatabase.makeEmpty()
        try appDB.writer.read { db in
            try #expect(db.tableExists("eqPreset"))
            try #expect(AppDatabase.migrator.appliedMigrations(db).contains("v3"))
            try #expect(AppDatabase.migrator.hasCompletedMigrations(db))
        }
    }

    @Test("eqPreset table has expected columns")
    func eqPresetTableColumns() throws {
        let appDB = try AppDatabase.makeEmpty()
        try appDB.writer.read { db in
            let columns = try db.columns(in: "eqPreset").map(\.name)
            #expect(columns.contains("id"))
            #expect(columns.contains("name"))
            #expect(columns.contains("bandGainsJson"))
            #expect(columns.contains("preamp"))
        }
    }

    // MARK: - FakeEQPresetStore

    @Test("FakeEQPresetStore save and load round-trips")
    func fakeSaveLoad() throws {
        let store = FakeEQPresetStore()
        let preset = EQPreset(name: "Fake Test", bandGains: [Float](repeating: 2, count: 10))
        try store.save(preset)
        let loaded = try store.loadAll()
        #expect(loaded.count == 1)
        #expect(loaded.first?.name == "Fake Test")
    }

    @Test("FakeEQPresetStore delete removes preset")
    func fakeDelete() throws {
        let store = FakeEQPresetStore(presets: [
            EQPreset(name: "Keep", bandGains: [Float](repeating: 0, count: 10)),
            EQPreset(name: "Remove", bandGains: [Float](repeating: 0, count: 10)),
        ])
        try store.delete(named: "Remove")
        let loaded = try store.loadAll()
        #expect(loaded.count == 1)
        #expect(loaded.first?.name == "Keep")
    }

    @Test("FakeEQPresetStore import/export round-trips")
    func fakeImportExport() throws {
        let store = FakeEQPresetStore()
        try store.save(EQPreset(name: "Fake Export", bandGains: [Float](repeating: 5, count: 10)))
        let data = try store.exportJSON()
        let store2 = FakeEQPresetStore()
        try store2.importJSON(data)
        let loaded = try store2.loadAll()
        #expect(loaded.count == 1)
        #expect(loaded.first?.name == "Fake Export")
    }
}
