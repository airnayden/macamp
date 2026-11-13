import Foundation
import GRDB
import Persistence
import Testing

/// A byte-compatible stand-in for `AudioEngine.ParametricFilter`.
///
/// `Persistence` (and therefore `PersistenceTests`) must not depend on `AudioEngine`,
/// so the filter shape is restated here rather than imported. The four property names
/// and the `String`-raw-value type token ARE the stored wire format — if
/// `ParametricFilter` ever renames one of them, a bank written by an older build stops
/// decoding, so pinning the spelling in the persistence suite is the point of this type
/// rather than an accident of it.
private struct StoredFilter: Codable, Equatable {
    var type: String
    var frequency: Double
    var gainDB: Double
    var qFactor: Double
}

private enum Fixtures {
    static let bank: [StoredFilter] = [
        StoredFilter(type: "LSC", frequency: 105, gainDB: -3.9, qFactor: 0.7),
        StoredFilter(type: "PK", frequency: 1130, gainDB: 2.4, qFactor: 1.42),
        StoredFilter(type: "HSC", frequency: 10000, gainDB: 1.1, qFactor: 0.7),
    ]

    static func preset(
        name: String,
        filters: [StoredFilter] = Fixtures.bank,
        preamp: Double? = -6.1
    ) throws -> ParametricEQPreset {
        try ParametricEQPreset(name: name, filters: filters, preamp: preamp)
    }

    /// Hoisted out of `#require` on purpose: the macro decomposes its argument into a
    /// NON-throwing closure, so `try #require(try store.loadAll().first)` does not
    /// compile.
    static func onlyPreset(in store: some ParametricEQPresetStoring) throws -> ParametricEQPreset {
        let loaded = try store.loadAll()
        return try #require(loaded.first)
    }
}

@Suite("ParametricEQPresetSchemaTests")
struct ParametricEQPresetSchemaTests {
    @Test("v19 creates parametricEQPreset with the four declared columns")
    func v19CreatesTable() throws {
        let appDB = try AppDatabase.makeEmpty()
        try appDB.writer.read { db in
            try #expect(db.tableExists("parametricEQPreset"))
            let columns = try db.columns(in: "parametricEQPreset")
            #expect(columns.map(\.name) == ["id", "name", "filtersJson", "preamp"])

            let primary = try #require(columns.first { $0.primaryKeyIndex == 1 })
            #expect(primary.name == "id")
            #expect(primary.type.uppercased() == "INTEGER")

            // An INTEGER PRIMARY KEY is a rowid alias and SQLite reports it `notnull = 0`
            // even though it can never hold NULL, so the key is partitioned out here.
            let required = Set(columns.filter(\.isNotNull).map(\.name))
            #expect(required == ["name", "filtersJson"])
            #expect(columns.first { $0.name == "preamp" }?.isNotNull == false)
        }
    }

    @Test("name carries a UNIQUE constraint the database itself enforces")
    func nameIsUnique() throws {
        let appDB = try AppDatabase.makeEmpty()
        try appDB.writer.write { db in
            try db.execute(
                sql: "INSERT INTO parametricEQPreset (name, filtersJson) VALUES (?, ?)",
                arguments: ["HD 650", "[]"]
            )
        }
        #expect(throws: (any Error).self) {
            try appDB.writer.write { db in
                try db.execute(
                    sql: "INSERT INTO parametricEQPreset (name, filtersJson) VALUES (?, ?)",
                    arguments: ["HD 650", "[]"]
                )
            }
        }
    }

    @Test("parametricEQPreset declares no foreign keys")
    func noForeignKeys() throws {
        let appDB = try AppDatabase.makeEmpty()
        try appDB.writer.read { db in
            let destinations = try db.foreignKeys(on: "parametricEQPreset").map(\.destinationTable)
            #expect(destinations.isEmpty, "parametricEQPreset must not reference \(destinations)")
        }
    }

    @Test("v18→head lands the ledger on v21 and adds the table empty")
    func migratesV18ToHead() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v18")
        let existsBefore = try queue.read { db in try db.tableExists("parametricEQPreset") }
        #expect(!existsBefore)

        try AppDatabase.migrator.migrate(queue)

        try queue.read { db in
            try #expect(db.tableExists("parametricEQPreset"))
            try #expect(AppDatabase.migrator.appliedMigrations(db).last == "v21")
            let rows = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM parametricEQPreset") ?? -1
            #expect(rows == 0)
        }
    }

    /// v19 must be additive beside the v3 graphic-EQ store, never a rewrite of it: the
    /// `eqPreset` table keeps its own columns, and a graphic preset written before v19
    /// survives the migration byte-identical.
    @Test("v19 leaves the v3 eqPreset table and its rows alone")
    func leavesGraphicEQPresetsAlone() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v18")
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO eqPreset (name, bandGainsJson, preamp) VALUES (?, ?, ?)",
                arguments: ["Rock", "[1,2,3,4,5,6,7,8,9,10]", -2.0]
            )
        }

        try AppDatabase.migrator.migrate(queue)

        try queue.read { db in
            let columns = try db.columns(in: "eqPreset").map(\.name)
            #expect(columns == ["id", "name", "bandGainsJson", "preamp"])
            let json = try String.fetchOne(db, sql: "SELECT bandGainsJson FROM eqPreset WHERE name = 'Rock'")
            #expect(json == "[1,2,3,4,5,6,7,8,9,10]")
            let preamp = try Double.fetchOne(db, sql: "SELECT preamp FROM eqPreset WHERE name = 'Rock'")
            #expect(preamp == -2.0)
        }
    }

    /// The two stores must stay independent: a parametric preset named like a graphic
    /// one is a different row in a different table, not a collision.
    @Test("a graphic and a parametric preset may share a name")
    func storesAreIndependent() throws {
        let appDB = try AppDatabase.makeEmpty()
        let graphic = GRDBEQPresetStore(appDB)
        let parametric = GRDBParametricEQPresetStore(appDB)
        try graphic.save(EQPreset(name: "Shared", bandGains: [Float](repeating: 1, count: 10)))
        try parametric.save(Fixtures.preset(name: "Shared"))

        let graphicPresets = try graphic.loadAll()
        #expect(graphicPresets.count == 1)
        #expect(graphicPresets.first?.bandGains.count == 10)
        #expect(try parametric.loadAll().count == 1)
    }
}

@Suite("ParametricEQPresetStoreTests")
struct ParametricEQPresetStoreTests {
    @Test("save and load round-trips every filter exactly")
    func saveLoadRoundTrip() throws {
        let appDB = try AppDatabase.makeEmpty()
        let store = GRDBParametricEQPresetStore(appDB)
        try store.save(Fixtures.preset(name: "HD 650"))

        let loaded = try Fixtures.onlyPreset(in: store)
        #expect(loaded.name == "HD 650")
        #expect(loaded.preamp == -6.1)
        #expect(try loaded.filters(as: StoredFilter.self) == Fixtures.bank)
    }

    @Test("filter order and fractional values survive the JSON round-trip")
    func roundTripIsOrderAndPrecisionPreserving() throws {
        let appDB = try AppDatabase.makeEmpty()
        let store = GRDBParametricEQPresetStore(appDB)
        let bank = [
            StoredFilter(type: "PK", frequency: 21.123456789, gainDB: -0.05, qFactor: 5.75),
            StoredFilter(type: "PK", frequency: 19999.5, gainDB: 23.999, qFactor: 0.182),
        ]
        try store.save(Fixtures.preset(name: "Precision", filters: bank, preamp: -0.00025))

        let loaded = try Fixtures.onlyPreset(in: store)
        #expect(try loaded.filters(as: StoredFilter.self) == bank)
        #expect(loaded.preamp == -0.00025)
    }

    @Test("an empty filter bank round-trips as an empty array, not as nil")
    func emptyBankRoundTrips() throws {
        let appDB = try AppDatabase.makeEmpty()
        let store = GRDBParametricEQPresetStore(appDB)
        try store.save(Fixtures.preset(name: "Bypass", filters: [], preamp: nil))

        let loaded = try Fixtures.onlyPreset(in: store)
        #expect(loaded.preamp == nil)
        #expect(try loaded.filters(as: StoredFilter.self).isEmpty)
    }

    @Test("save with the same name replaces the existing row rather than duplicating")
    func saveUpsertsOnName() throws {
        let appDB = try AppDatabase.makeEmpty()
        let store = GRDBParametricEQPresetStore(appDB)
        try store.save(Fixtures.preset(name: "Upsert"))
        let replacement = [StoredFilter(type: "PK", frequency: 440, gainDB: -9, qFactor: 2)]
        try store.save(Fixtures.preset(name: "Upsert", filters: replacement, preamp: 0))

        let loaded = try store.loadAll()
        #expect(loaded.count == 1)
        #expect(try loaded[0].filters(as: StoredFilter.self) == replacement)
        #expect(loaded[0].preamp == 0)

        let rowCount = try appDB.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM parametricEQPreset") ?? -1
        }
        #expect(rowCount == 1)
    }

    /// An upsert must reuse the existing row, not delete-and-reinsert: a stable `id` is
    /// what lets a later feature reference a preset by key.
    @Test("an upsert keeps the row's primary key")
    func upsertKeepsTheIdentity() throws {
        let appDB = try AppDatabase.makeEmpty()
        let store = GRDBParametricEQPresetStore(appDB)
        try store.save(Fixtures.preset(name: "Stable"))
        let first = try appDB.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM parametricEQPreset WHERE name = 'Stable'")
        }
        try store.save(Fixtures.preset(name: "Stable", filters: [], preamp: nil))
        let second = try appDB.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM parametricEQPreset WHERE name = 'Stable'")
        }
        #expect(first != nil)
        #expect(first == second)
    }

    @Test("loadAll returns presets ordered by name")
    func loadAllOrdered() throws {
        let appDB = try AppDatabase.makeEmpty()
        let store = GRDBParametricEQPresetStore(appDB)
        for name in ["Zebra", "Alpha", "Mango"] {
            try store.save(Fixtures.preset(name: name))
        }
        #expect(try store.loadAll().map(\.name) == ["Alpha", "Mango", "Zebra"])
    }

    @Test("delete removes a preset by name and is a no-op for an unknown one")
    func deleteByName() throws {
        let appDB = try AppDatabase.makeEmpty()
        let store = GRDBParametricEQPresetStore(appDB)
        try store.save(Fixtures.preset(name: "To Delete"))
        try store.delete(named: "Ghost")
        #expect(try store.loadAll().count == 1)
        try store.delete(named: "To Delete")
        #expect(try store.loadAll().isEmpty)
    }

    /// The failure path the opaque-JSON design exists for: a row whose `filtersJson` is
    /// unreadable must fail **only** for its own owner. `loadAll` never decodes, so the
    /// siblings still load and the corrupt preset is still deletable.
    @Test("a corrupt filtersJson row throws on decode without poisoning loadAll")
    func corruptRowDoesNotPoisonLoadAll() throws {
        let appDB = try AppDatabase.makeEmpty()
        let store = GRDBParametricEQPresetStore(appDB)
        try store.save(Fixtures.preset(name: "Good"))
        try appDB.writer.write { db in
            try db.execute(
                sql: "INSERT INTO parametricEQPreset (name, filtersJson) VALUES (?, ?)",
                arguments: ["Corrupt", "{ not json"]
            )
        }

        let loaded = try store.loadAll()
        #expect(loaded.map(\.name) == ["Corrupt", "Good"])

        let corrupt = try #require(loaded.first { $0.name == "Corrupt" })
        #expect(throws: (any Error).self) { try corrupt.filters(as: StoredFilter.self) }

        let good = try #require(loaded.first { $0.name == "Good" })
        #expect(try good.filters(as: StoredFilter.self) == Fixtures.bank)

        try store.delete(named: "Corrupt")
        #expect(try store.loadAll().map(\.name) == ["Good"])
    }

    @Test("well-formed JSON of the wrong shape also fails only on decode")
    func wrongShapeJSONFailsOnDecode() throws {
        let appDB = try AppDatabase.makeEmpty()
        let store = GRDBParametricEQPresetStore(appDB)
        try appDB.writer.write { db in
            try db.execute(
                sql: "INSERT INTO parametricEQPreset (name, filtersJson) VALUES (?, ?)",
                arguments: ["Object", #"{"filters": []}"#]
            )
        }

        let loaded = try Fixtures.onlyPreset(in: store)
        #expect(loaded.filtersJson == #"{"filters": []}"#)
        #expect(throws: DecodingError.self) { try loaded.filters(as: StoredFilter.self) }
    }
}

@Suite("ParametricEQPresetFakeStoreTests")
struct ParametricEQPresetFakeStoreTests {
    @Test("the fake matches the GRDB store's CRUD and ordering contract")
    func fakeMatchesTheContract() throws {
        let seeded = try Fixtures.preset(name: "Seeded")
        let fake = FakeParametricEQPresetStore(presets: [seeded])
        try fake.save(Fixtures.preset(name: "Alpha"))
        #expect(try fake.loadAll().map(\.name) == ["Alpha", "Seeded"])

        try fake.save(Fixtures.preset(name: "Alpha", filters: [], preamp: nil))
        let presets = try fake.loadAll()
        #expect(presets.count == 2)
        let alpha = try #require(presets.first)
        #expect(try alpha.filters(as: StoredFilter.self).isEmpty)
        #expect(alpha.preamp == nil)

        try fake.delete(named: "Ghost")
        #expect(try fake.loadAll().count == 2)
        try fake.delete(named: "Seeded")
        #expect(try fake.loadAll().map(\.name) == ["Alpha"])
    }

    @Test("the fake is usable through the protocol existential")
    func fakeSatisfiesTheProtocol() throws {
        let store: any ParametricEQPresetStoring = FakeParametricEQPresetStore()
        try store.save(Fixtures.preset(name: "Via Protocol"))
        #expect(try store.loadAll().map(\.name) == ["Via Protocol"])
    }
}
