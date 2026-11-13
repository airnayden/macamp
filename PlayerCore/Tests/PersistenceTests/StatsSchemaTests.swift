import Foundation
import GRDB
import Persistence
import Testing

/// Shape and round-trip coverage for the `v15` listening-statistics tables.
@Suite("StatsSchemaTests")
struct StatsSchemaTests {
    @Test("v15 creates all four statistics tables")
    func v15CreatesTables() throws {
        let appDB = try AppDatabase.makeEmpty()
        try appDB.writer.read { db in
            for table in ["playEvent", "playEventRollup", "folderTrackOrder", "playSegmentHeat"] {
                try #expect(db.tableExists(table), "missing table \(table)")
            }
        }
    }

    @Test("v15 creates the query indexes")
    func v15CreatesIndexes() throws {
        let appDB = try AppDatabase.makeEmpty()
        let expected: [String: [String]] = [
            "playEvent": ["playEvent_on_profileId_startedAt", "playEvent_on_profileId_trackId"],
            "playEventRollup": ["playEventRollup_on_profileId_yearMonth"],
            "folderTrackOrder": ["folderTrackOrder_on_profileId_rootPath_position"],
        ]
        try appDB.writer.read { db in
            for (table, names) in expected {
                let actual = try db.indexes(on: table).map(\.name)
                for name in names {
                    #expect(actual.contains(name), "missing index \(name)")
                }
            }
        }
    }

    @Test("playEvent and playSegmentHeat declare no foreign key on trackId")
    func statsTablesHaveNoTrackForeignKey() throws {
        let appDB = try AppDatabase.makeEmpty()
        try appDB.writer.read { db in
            for table in ["playEvent", "playSegmentHeat"] {
                let destinations = try db.foreignKeys(on: table).map(\.destinationTable)
                #expect(!destinations.contains("track"), "\(table) must not reference track")
                #expect(destinations.contains("profile"), "\(table) must cascade from profile")
            }
        }
    }

    @Test("folderTrackOrder cascades from both profile and track")
    func folderTrackOrderReferencesBoth() throws {
        let appDB = try AppDatabase.makeEmpty()
        try appDB.writer.read { db in
            let destinations = try db.foreignKeys(on: "folderTrackOrder").map(\.destinationTable)
            #expect(Set(destinations) == ["profile", "track"])
        }
    }

    @Test("a play event round-trips every captured field")
    func playEventRoundTrip() throws {
        let appDB = try AppDatabase.makeEmpty()
        var event = StatsFixtures.event(trackId: 4242)
        try appDB.writer.write { db in try event.insert(db) }
        let eventId = try #require(event.id)

        let stored = try appDB.writer.read { db in try PlayEventRecord.fetchOne(db, key: eventId) }
        #expect(stored == event)
        #expect(stored?.utcOffsetSeconds == 7200)
        #expect(stored?.trackId == 4242)
    }

    @Test("a play event without a track or a source surface is accepted")
    func playEventAllowsMissingBacklinks() throws {
        let appDB = try AppDatabase.makeEmpty()
        var event = StatsFixtures.event(trackId: nil)
        event.sourceSurface = nil
        try appDB.writer.write { db in try event.insert(db) }
        let eventId = try #require(event.id)

        let stored = try appDB.writer.read { db in try PlayEventRecord.fetchOne(db, key: eventId) }
        #expect(stored?.trackId == nil)
        #expect(stored?.sourceSurface == nil)
    }

    @Test("a folder order row round-trips under its composite key")
    func folderTrackOrderRoundTrip() throws {
        let appDB = try AppDatabase.makeEmpty()
        let trackId = try StatsFixtures.seedTrack(appDB, path: "/music/order.flac")
        let record = FolderTrackOrderRecord(
            profileId: ProfileRecord.guestID,
            rootPath: "/music",
            trackId: trackId,
            position: 7
        )
        try appDB.writer.write { db in try record.insert(db) }

        let stored = try appDB.writer.read { db in
            try FolderTrackOrderRecord.fetchOne(
                db,
                key: ["profileId": ProfileRecord.guestID, "rootPath": "/music", "trackId": trackId]
            )
        }
        #expect(stored == record)
    }

    @Test("nested roots keep independent order for the same track")
    func folderTrackOrderIsPerRoot() throws {
        let appDB = try AppDatabase.makeEmpty()
        let trackId = try StatsFixtures.seedTrack(appDB, path: "/music/nested/song.flac")
        try appDB.writer.write { db in
            try FolderTrackOrderRecord(
                profileId: ProfileRecord.guestID, rootPath: "/music", trackId: trackId, position: 0
            ).insert(db)
            try FolderTrackOrderRecord(
                profileId: ProfileRecord.guestID, rootPath: "/music/nested", trackId: trackId, position: 3
            ).insert(db)
        }

        let positions = try appDB.writer.read { db in
            try Int.fetchAll(
                db,
                sql: "SELECT position FROM folderTrackOrder WHERE trackId = ? ORDER BY rootPath",
                arguments: [trackId]
            )
        }
        #expect(positions == [0, 3])
    }

    @Test("v14 databases migrate forward to head without losing their rows")
    func migratesV14ToHead() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v14")
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO profile (id, name, createdAt) VALUES (?, ?, datetime('now'))",
                arguments: [2, "Existing"]
            )
        }

        try AppDatabase.migrator.migrate(queue)

        try queue.read { db in
            try #expect(db.tableExists("playEvent"))
            try #expect(db.tableExists("playSegmentHeat"))
            let name = try String.fetchOne(db, sql: "SELECT name FROM profile WHERE id = 2")
            #expect(name == "Existing")
            try #expect(AppDatabase.migrator.appliedMigrations(db).last == "v21")
        }
    }
}
