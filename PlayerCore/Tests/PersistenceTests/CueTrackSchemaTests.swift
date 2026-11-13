import Foundation
import GRDB
import Persistence
import Testing

/// Shape and forward-migration coverage for the `v20` guarded `track` rebuild.
@Suite("CueTrackSchemaTests")
struct CueTrackSchemaTests {
    @Test("v20 adds the four cue columns with their whole-file defaults")
    func v20AddsCueColumns() throws {
        let appDB = try AppDatabase.makeEmpty()
        try appDB.writer.read { db in
            let columns = try db.columns(in: "track")
            let cue = columns.filter { $0.name.hasPrefix("cue") }
            #expect(cue.map(\.name) == ["cueSheetPath", "cueStartFrame", "cueEndFrame", "cueSuppressed"])
            #expect(Set(cue.filter(\.isNotNull).map(\.name)) == ["cueStartFrame", "cueSuppressed"])
        }
        try appDB.writer.write { db in
            try db.execute(sql: "INSERT INTO track (filePath) VALUES ('/plain.flac')")
        }
        try appDB.writer.read { db in
            try #expect(DownloadHistoryFixtures.nonCueTrackCount(db) == 1)
        }
    }

    /// The whole point of the rebuild: the v1 `filePath` UNIQUE was a COLUMN
    /// constraint, and only a rebuild can replace it with the two-column one.
    @Test("v20 replaces the single-column filePath UNIQUE with the cue pair")
    func v20ReplacesTheUniqueConstraint() throws {
        let appDB = try AppDatabase.makeEmpty()
        try appDB.writer.read { db in
            let unique = try db.indexes(on: "track")
                .filter(\.isUnique)
                .map(\.columns)
            #expect(unique == [["filePath", "cueStartFrame"]])
        }
    }

    @Test("v19→v20 leaves every cascading child table's rows standing")
    func cascadingChildrenSurvive() throws {
        let queue = try CueTrackFixtures.seededV19Queue()
        let before = try queue.read { db in
            try CueTrackFixtures.rowCounts(db, tables: CueTrackFixtures.cascadingChildTables)
        }
        #expect(before == [2, 1, 1, 1, 1], "the fixture must populate every cascading child")

        try AppDatabase.migrator.migrate(queue)

        let after = try queue.read { db in
            try CueTrackFixtures.rowCounts(db, tables: CueTrackFixtures.cascadingChildTables)
        }
        #expect(after == before)
    }

    /// `playEvent` and `playSegmentHeat` hold a bare `trackId` with no foreign key, so
    /// they can only be lost by the rebuild deleting them outright.
    @Test("v19→v20 leaves the bare-trackId stats rows standing")
    func bareTrackIDStatsSurvive() throws {
        let queue = try CueTrackFixtures.seededV19Queue()
        let before = try queue.read { db in
            try CueTrackFixtures.rowCounts(db, tables: CueTrackFixtures.bareTrackIDTables)
        }
        #expect(before == [1, 1])

        try AppDatabase.migrator.migrate(queue)

        let after = try queue.read { db in
            try CueTrackFixtures.rowCounts(db, tables: CueTrackFixtures.bareTrackIDTables)
        }
        #expect(after == before)
    }

    /// The worst data-loss path, named on its own: a rebuild that minted fresh rowids
    /// would leave `playlistTrack` pointing at nothing, and the count assertion above
    /// would still pass because the rows themselves would still be there.
    @Test("a track's playlist membership survives v20")
    func playlistMembershipSurvives() throws {
        let queue = try CueTrackFixtures.seededV19Queue()

        try AppDatabase.migrator.migrate(queue)

        try queue.read { db in
            let resolved = try String.fetchAll(db, sql: """
            SELECT t.title FROM playlistTrack pt
            JOIN track t ON t.id = pt.trackId
            WHERE pt.playlistId = ?
            ORDER BY pt.position
            """, arguments: [CueTrackFixtures.playlistID])
            #expect(resolved == [CueTrackFixtures.trackTitle, "Hey You"])
        }
    }

    @Test("v20 preserves every track rowid")
    func rowIDsArePreserved() throws {
        let queue = try CueTrackFixtures.seededV19Queue()
        let before = try queue.read { db in try Int64.fetchAll(db, sql: "SELECT id FROM track ORDER BY id") }
        #expect(before == [CueTrackFixtures.trackID, CueTrackFixtures.otherTrackID])

        try AppDatabase.migrator.migrate(queue)

        try queue.read { db in
            let after = try Int64.fetchAll(db, sql: "SELECT id FROM track ORDER BY id")
            #expect(after == before)
            let path = try String.fetchOne(
                db,
                sql: "SELECT filePath FROM track WHERE id = ?",
                arguments: [CueTrackFixtures.trackID]
            )
            #expect(path == CueTrackFixtures.trackPath)
        }
    }

    @Test("PRAGMA foreign_key_check is clean after v20")
    func foreignKeysAreIntact() throws {
        let queue = try CueTrackFixtures.seededV19Queue()

        try AppDatabase.migrator.migrate(queue)

        try queue.read { db in
            let violations = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
            #expect(violations.isEmpty, "\(violations.count) dangling reference(s) after the rebuild")
        }
    }

    @Test("FTS5 search still finds the pre-migration titles")
    func searchSurvivesTheRebuild() throws {
        let queue = try CueTrackFixtures.seededV19Queue()
        let before = try queue.read { db in try CueTrackFixtures.searchRowIDs(db, matching: "comfortably") }
        #expect(before == [CueTrackFixtures.trackID])

        try AppDatabase.migrator.migrate(queue)

        try queue.read { db in
            try #expect(CueTrackFixtures.searchRowIDs(db, matching: "comfortably") == before)
            try #expect(CueTrackFixtures.searchRowIDs(db, matching: "floyd").count == 2)
        }
    }

    /// The assertion that catches the mistake this migration is most likely to make.
    ///
    /// `DROP TABLE track` takes the FTS5 sync triggers with it, because
    /// `synchronize(withTable:)` installed them ON `track`. A rebuild that repopulated
    /// the index with a bare `INSERT INTO trackSearch(trackSearch) VALUES('rebuild')`
    /// would pass every search test above and then go silently stale from the next
    /// scan onwards — so all three trigger directions are asserted separately.
    @Test("a post-v20 INSERT propagates to trackSearch")
    func insertTriggerIsLive() throws {
        let appDB = try AppDatabase.makeEmpty()
        try appDB.writer.write { db in
            try db.execute(sql: """
            INSERT INTO track (id, filePath, title) VALUES (5, '/new.flac', 'Wish You Were Here')
            """)
        }
        try appDB.writer.read { db in
            try #expect(CueTrackFixtures.searchRowIDs(db, matching: "wish") == [5])
        }
    }

    @Test("a post-v20 UPDATE propagates to trackSearch")
    func updateTriggerIsLive() throws {
        let appDB = try AppDatabase.makeEmpty()
        try appDB.writer.write { db in
            try db.execute(sql: "INSERT INTO track (id, filePath, title) VALUES (5, '/new.flac', 'Echoes')")
            try db.execute(sql: "UPDATE track SET title = 'Obscured by Clouds' WHERE id = 5")
        }
        try appDB.writer.read { db in
            try #expect(CueTrackFixtures.searchRowIDs(db, matching: "echoes").isEmpty)
            try #expect(CueTrackFixtures.searchRowIDs(db, matching: "obscured") == [5])
        }
    }

    @Test("a post-v20 DELETE propagates to trackSearch")
    func deleteTriggerIsLive() throws {
        let appDB = try AppDatabase.makeEmpty()
        try appDB.writer.write { db in
            try db.execute(sql: "INSERT INTO track (id, filePath, title) VALUES (5, '/new.flac', 'Echoes')")
            try db.execute(sql: "DELETE FROM track WHERE id = 5")
        }
        try appDB.writer.read { db in
            try #expect(CueTrackFixtures.searchRowIDs(db, matching: "echoes").isEmpty)
        }
    }

    @Test("v20 restores every index the dropped track table carried")
    func indexesAreRestored() throws {
        let appDB = try AppDatabase.makeEmpty()
        try appDB.writer.read { db in
            let names = try Set(db.indexes(on: "track").map(\.name))
            #expect(names.isSuperset(of: [
                "track_on_artistId", "track_on_albumId",
                "track_on_availability", "track_on_dateAdded",
                "track_on_isFavourite_customPosition", "track_on_genre",
                "track_on_filePath_customPosition",
            ]))
        }
    }

    /// The fresh-install path: v20 runs against a `track` table with no rows at all.
    @Test("v20 migrates an empty v19 database")
    func migratesAnEmptyV19Database() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v19")

        try AppDatabase.migrator.migrate(queue)

        try queue.read { db in
            try #expect(AppDatabase.migrator.appliedMigrations(db).last == "v21")
            try #expect(Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track") == 0)
            try #expect(db.columns(in: "track").contains { $0.name == "cueStartFrame" })
        }
        try queue.write { db in
            try db.execute(sql: "INSERT INTO track (filePath, title) VALUES ('/fresh.flac', 'Fresh')")
        }
        try queue.read { db in
            try #expect(CueTrackFixtures.searchRowIDs(db, matching: "fresh").count == 1)
        }
    }
}
