import Foundation
import GRDB
import Persistence
import Testing

/// Forward-migration coverage for `v16`: a populated `v15` database must reach head
/// with every row intact, and the new `smartPlaylist` columns must materialise from
/// their SQL defaults without a backfill pass.
@Suite("AIMigrationTests")
struct AIMigrationTests {
    /// Seeds a `v15` database with one row in every table `v16` creates, alters, or
    /// claims to leave alone. Raw SQL keeps the fixture decoupled from the current
    /// record shapes, matching the other pre-migration seeds in this target.
    private static func makeSeededV15Queue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v15")
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO track (id, filePath, title) VALUES (?, ?, ?)",
                arguments: [42, "/music/seeded.flac", "Seeded"]
            )
            try db.execute(
                sql: "INSERT INTO playlist (id, name, profileId) VALUES (?, ?, 1)",
                arguments: [7, "Seeded List"]
            )
            try db.execute(
                sql: "INSERT INTO smartPlaylist (playlistId, rulesJson) VALUES (?, ?)",
                arguments: [7, #"{"limit":50}"#]
            )
            try db.execute(sql: """
            INSERT INTO playEvent
                (profileId, trackId, artistName, title, startedAt, utcOffsetSeconds)
            VALUES (1, 42, 'Pink Floyd', 'Seeded', 1700000000.0, 7200)
            """)
        }
        return queue
    }

    @Test("v15→v16 creates the playlist-intelligence tables and lands the ledger on head")
    func migratesV15ToV16() throws {
        let queue = try Self.makeSeededV15Queue()
        let existsBefore = try queue.read { db in try db.tableExists("trackAudioFeature") }
        #expect(!existsBefore)

        try AppDatabase.migrator.migrate(queue)

        try queue.read { db in
            try #expect(db.tableExists("trackAudioFeature"))
            try #expect(db.tableExists("generatedPlaylist"))
            try #expect(AppDatabase.migrator.appliedMigrations(db).last == "v21")
        }
    }

    @Test("v15→v16 versions existing smart-playlist rules to schema 1, never evaluated")
    func migratesV15ToV16AddingSmartPlaylistColumns() throws {
        let queue = try Self.makeSeededV15Queue()

        try AppDatabase.migrator.migrate(queue)

        try queue.read { db in
            let columns = try db.columns(in: "smartPlaylist")
            let versionColumn = try #require(columns.first { $0.name == "rulesVersion" })
            #expect(versionColumn.isNotNull)
            let evaluatedColumn = try #require(columns.first { $0.name == "lastEvaluatedAt" })
            #expect(evaluatedColumn.isNotNull == false)

            let fetched = try SmartPlaylistRecord.fetchOne(db)
            let stored = try #require(fetched)
            #expect(stored.rulesVersion == 1)
            #expect(stored.lastEvaluatedAt == nil)
            #expect(stored.rulesJson == #"{"limit":50}"#)
        }
    }

    /// A row inserted *after* the migration must also pick up the default, which proves
    /// the `DEFAULT 1` clause lives on the column rather than only on the ALTER rewrite.
    @Test("smartPlaylist.rulesVersion defaults to 1 for rows written after v16")
    func rulesVersionDefaultsForNewRows() throws {
        let queue = try Self.makeSeededV15Queue()
        try AppDatabase.migrator.migrate(queue)

        try queue.write { db in
            try db.execute(sql: "INSERT INTO playlist (id, name, profileId) VALUES (8, 'Fresh', 1)")
            try db.execute(
                sql: "INSERT INTO smartPlaylist (playlistId, rulesJson) VALUES (?, ?)",
                arguments: [8, #"{"limit":10}"#]
            )
        }

        let version = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT rulesVersion FROM smartPlaylist WHERE playlistId = 8")
        }
        #expect(version == 1)
    }

    @Test("v15→v16 preserves every seeded row")
    func migratesV15ToV16Losslessly() throws {
        let tables = ["track", "playlist", "smartPlaylist", "playEvent"]
        let queue = try Self.makeSeededV15Queue()
        let before = try queue.read { db in
            try tables.map { try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)") ?? -1 }
        }

        try AppDatabase.migrator.migrate(queue)

        let after = try queue.read { db in
            try tables.map { try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)") ?? -1 }
        }
        #expect(before == [1, 1, 1, 1])
        #expect(after == before)

        try queue.read { db in
            let title = try String.fetchOne(db, sql: "SELECT title FROM playEvent WHERE trackId = 42")
            #expect(title == "Seeded")
            let path = try String.fetchOne(db, sql: "SELECT filePath FROM track WHERE id = 42")
            #expect(path == "/music/seeded.flac")
        }
    }
}
