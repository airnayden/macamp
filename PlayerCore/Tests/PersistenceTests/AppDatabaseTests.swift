import Foundation
import GRDB
import Persistence
import Testing

@Suite("AppDatabaseTests")
struct AppDatabaseTests {
    @Test("makeEmpty() migrates to head")
    func makeEmptyMigratesToHead() throws {
        let appDB = try AppDatabase.makeEmpty()
        try appDB.writer.read { db in
            try #expect(AppDatabase.migrator.appliedMigrations(db) == [
                "v1",
                "v2",
                "v3",
                "v4",
                "v5",
                "v6",
                "v7",
                "v8",
                "v9",
                "v10", "v11", "v12", "v13", "v14", "v15", "v16", "v17", "v18", "v19", "v20", "v21",
            ])
            try #expect(AppDatabase.migrator.hasCompletedMigrations(db))
        }
    }

    @Test("v12 creates the profile tables and seeds the Guest row")
    func v12ProfileSchema() throws {
        let appDB = try AppDatabase.makeEmpty()
        try appDB.writer.read { db in
            for table in ["profile", "profileTrackState", "libraryRoot"] {
                try #expect(db.tableExists(table), "missing table \(table)")
            }
            let guestName = try String.fetchOne(db, sql: "SELECT name FROM profile WHERE id = 1")
            #expect(guestName == "Guest")
            let profiles = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM profile") ?? -1
            #expect(profiles == 1)
            try #expect(db.columns(in: "playlist").contains { $0.name == "profileId" })
        }
    }

    @Test("v13 adds a nullable profile.avatarImagePath; the seeded Guest row is NULL")
    func v13ProfileAvatarImagePath() throws {
        let appDB = try AppDatabase.makeEmpty()
        try appDB.writer.read { db in
            let column = try db.columns(in: "profile").first { $0.name == "avatarImagePath" }
            let avatarColumn = try #require(column)
            #expect(avatarColumn.isNotNull == false)
            let guestPath = try String.fetchOne(db, sql: "SELECT avatarImagePath FROM profile WHERE id = 1")
            #expect(guestPath == nil)
        }
    }

    @Test("all v1 tables exist")
    func allTablesExist() throws {
        let appDB = try AppDatabase.makeEmpty()
        try appDB.writer.read { db in
            for table in [
                "artist", "album", "track", "playlist",
                "playlistTrack", "smartPlaylist", "artworkRef", "bookmark",
            ] {
                try #expect(db.tableExists(table), "missing table \(table)")
            }
        }
    }

    @Test("FTS5 virtual table is NOT created in v1 (reserved for v2)")
    func ftsAbsentInV1() throws {
        let appDB = try AppDatabase.makeEmpty()
        try appDB.writer.read { db in
            try #expect(!db.tableExists("trackFts"))
            try #expect(!db.tableExists("track_fts"))
        }
    }
}
