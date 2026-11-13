import Foundation
import GRDB
import Persistence
import Testing

@Suite("MigrationTests", .serialized)
struct MigrationTests {
    enum Seed {
        static let artistName = "Pink Floyd"
        static let albumTitle = "The Wall"
        static let albumYear = 1979
        static let trackPath = "/Music/PinkFloyd/TheWall/ComfortablyNumb.flac"
        static let trackTitle = "Comfortably Numb"
        static let playlistName = "Seeded Favorites"
    }

    static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("v1.sqlite")
    }

    /// The committed fixture is generated here once, then checked into git. On a
    /// machine that already has it, this is a no-op and the test simply copies
    /// it. This is exactly how the committed fixture was originally produced: run
    /// the v1 migration against an empty on-disk DB, then seed deterministic rows.
    static func ensureFixtureExists() throws {
        let url = fixtureURL
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let queue = try DatabaseQueue(path: url.path)
        try AppDatabase.migrator.migrate(queue, upTo: "v1")
        try queue.write { db in
            var artist = ArtistRecord(name: Seed.artistName, sortName: Seed.artistName)
            try artist.insert(db)
            var album = AlbumRecord(
                title: Seed.albumTitle,
                sortTitle: Seed.albumTitle,
                artistId: artist.id,
                year: Seed.albumYear
            )
            try album.insert(db)
            var track = TrackRecord(
                filePath: Seed.trackPath,
                title: Seed.trackTitle,
                artistName: Seed.artistName,
                albumTitle: Seed.albumTitle,
                artistId: artist.id,
                albumId: album.id
            )
            try track.insert(db)
            var playlist = PlaylistRecord(name: Seed.playlistName)
            try playlist.insert(db)
            let playlistID = try #require(playlist.id)
            let trackID = try #require(track.id)
            var entry = PlaylistTrackRecord(playlistId: playlistID, trackId: trackID, position: 0)
            try entry.insert(db)
        }
    }

    private static func makeMigratedCopy() throws -> (AppDatabase, cleanup: () -> Void) {
        try ensureFixtureExists()
        let fileManager = FileManager.default
        let tempURL = fileManager.temporaryDirectory
            .appendingPathComponent("macamp-migration-\(UUID().uuidString).sqlite")
        try fileManager.copyItem(at: fixtureURL, to: tempURL)
        let appDB = try AppDatabase(DatabaseQueue(path: tempURL.path))
        return (appDB, { try? fileManager.removeItem(at: tempURL) })
    }

    @Test("committed v1 fixture exists and is non-empty")
    func fixtureIsCommitted() throws {
        try Self.ensureFixtureExists()
        let attrs = try FileManager.default.attributesOfItem(atPath: Self.fixtureURL.path)
        let size = try #require(attrs[.size] as? Int)
        #expect(size > 0)
    }

    @Test("forward-migrate a v1 fixture to head; migration ledger is correct")
    func migrationLedger() throws {
        let (appDB, cleanup) = try Self.makeMigratedCopy()
        defer { cleanup() }
        try appDB.writer.read { db in
            try #expect(AppDatabase.migrator.appliedMigrations(db).contains("v1"))
            try #expect(AppDatabase.migrator.hasCompletedMigrations(db))
        }
    }

    @Test("forward-migrate a v1 fixture to head; seeded data survives intact")
    func dataSurvives() throws {
        let (appDB, cleanup) = try Self.makeMigratedCopy()
        defer { cleanup() }
        try appDB.writer.read { db in
            let artists = try ArtistRecord.fetchAll(db)
            #expect(artists.count == 1)
            #expect(artists.first?.name == Self.Seed.artistName)

            let albums = try AlbumRecord.fetchAll(db)
            #expect(albums.count == 1)
            #expect(albums.first?.title == Self.Seed.albumTitle)
            #expect(albums.first?.year == Self.Seed.albumYear)

            let tracks = try TrackRecord.fetchAll(db)
            #expect(tracks.count == 1)
            #expect(tracks.first?.filePath == Self.Seed.trackPath)
            #expect(tracks.first?.title == Self.Seed.trackTitle)
            #expect(tracks.first?.availability == .present)

            let entries = try PlaylistTrackRecord.fetchAll(db)
            #expect(entries.count == 1)
            #expect(entries.first?.position == 0)
        }
    }

    @Test("forward-migrate a v1 fixture to head; relationships still resolve")
    func relationshipsSurvive() throws {
        let (appDB, cleanup) = try Self.makeMigratedCopy()
        defer { cleanup() }
        try appDB.writer.read { db in
            let loadedTrack = try TrackRecord.fetchOne(db)
            let track = try #require(loadedTrack)
            try #expect(track.artist.fetchOne(db)?.name == Self.Seed.artistName)
            try #expect(track.album.fetchOne(db)?.title == Self.Seed.albumTitle)
        }
    }

    @Test("all v1 tables present after migrating the fixture")
    func allTablesPresent() throws {
        let (appDB, cleanup) = try Self.makeMigratedCopy()
        defer { cleanup() }
        try appDB.writer.read { db in
            for table in [
                "artist", "album", "track", "playlist",
                "playlistTrack", "smartPlaylist", "artworkRef", "bookmark",
            ] {
                try #expect(db.tableExists(table), "missing table \(table)")
            }
        }
    }

    /// v5 adds a nullable `genre` column to `track`. The migration must be a pure
    /// `ALTER TABLE … ADD COLUMN`: existing rows survive untouched and their new
    /// `genre` is `NULL` (backfilled lazily on the next re-scan). Inserts use raw
    /// SQL so the test is decoupled from the current `TrackRecord` column set.
    @Test("v4→v5 adds a nullable genre column; existing rows survive as genre IS NULL")
    func migratesV4ToV5AddingGenre() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v4")
        try queue.write { db in
            for index in 0 ..< 1000 {
                try db.execute(
                    sql: "INSERT INTO track (filePath, title) VALUES (?, ?)",
                    arguments: ["/Music/track-\(index).flac", "Track \(index)"]
                )
            }
        }

        try AppDatabase.migrator.migrate(queue)

        try queue.read { db in
            try #expect(db.columns(in: "track").contains { $0.name == "genre" })
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track") ?? -1
            #expect(total == 1000)
            let nonNullGenre = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track WHERE genre IS NOT NULL") ?? -1
            #expect(nonNullGenre == 0)
        }
    }

    @Test("v5→v6 adds extended columns and backfills the artist/album graph")
    func migratesV5ToV6BackfillingGraph() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v5")
        try queue.write { db in
            let insert = "INSERT INTO track (filePath, title, artistName, albumTitle) VALUES (?, ?, ?, ?)"
            try db.execute(sql: insert, arguments: ["/Music/a.flac", "A", "Daft Punk", "Discovery"])
            try db.execute(sql: insert, arguments: ["/Music/b.flac", "B", "Daft Punk", "Discovery"])
            try db.execute(sql: insert, arguments: ["/Music/c.flac", "C", "Air", "Moon Safari"])
        }

        try AppDatabase.migrator.migrate(queue)

        try queue.read { db in
            for column in ["albumArtist", "composer", "year", "channelCount"] {
                try #expect(db.columns(in: "track").contains { $0.name == column })
            }
            try #expect(Int.fetchOne(db, sql: "SELECT COUNT(*) FROM artist") == 2)
            try #expect(Int.fetchOne(db, sql: "SELECT COUNT(*) FROM album") == 2)
            let linked = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM track WHERE artistId IS NOT NULL AND albumId IS NOT NULL"
            )
            #expect(linked == 3)
        }
    }

    @Test("v7→v8 adds isFavourite defaulting to 0 for existing rows")
    func migratesV7ToV8AddingFavourite() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v7")
        try queue.write { db in
            for index in 0 ..< 500 {
                try db.execute(
                    sql: "INSERT INTO track (filePath, title) VALUES (?, ?)",
                    arguments: ["/Music/fav-\(index).flac", "Track \(index)"]
                )
            }
        }

        try AppDatabase.migrator.migrate(queue)

        try queue.read { db in
            try #expect(db.columns(in: "track").contains { $0.name == "isFavourite" })
            let favourited = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track WHERE isFavourite = 1") ?? -1
            #expect(favourited == 0)
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track") ?? -1
            #expect(total == 500)
        }
    }

    @Test("head migration ledger ends at v21")
    func ledgerHeadIsV21() throws {
        let (appDB, cleanup) = try Self.makeMigratedCopy()
        defer { cleanup() }
        try appDB.writer.read { db in
            try #expect(AppDatabase.migrator.appliedMigrations(db).last == "v21")
        }
    }

    @Test("v9 creates the infoCache table with a unique (entityType, entityKey)")
    func migratesV8ToV9AddingInfoCache() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v8")
        let existsBefore = try queue.read { db in try db.tableExists("infoCache") }
        #expect(!existsBefore)

        try AppDatabase.migrator.migrate(queue)

        try queue.write { db in
            try #expect(db.tableExists("infoCache"))
            try db.execute(
                sql: "INSERT INTO infoCache (entityType, entityKey, infoJson, fetchedAt) VALUES (?, ?, ?, ?)",
                arguments: ["artist", "Pink Floyd", "{}", 1_000_000.0]
            )
        }
        #expect(throws: (any Error).self) {
            try queue.write { db in
                try db.execute(
                    sql: "INSERT INTO infoCache (entityType, entityKey, infoJson) VALUES (?, ?, ?)",
                    arguments: ["artist", "Pink Floyd", "{}"]
                )
            }
        }
    }
}

@Suite("ProfilesMigrationTests", .serialized)
struct ProfilesMigrationTests {
    private static func stateColumn(_ column: String) -> String {
        """
        SELECT pts.\(column) FROM profileTrackState pts
        JOIN track t ON t.id = pts.trackId WHERE t.filePath = ?
        """
    }

    @Test("v11→v12 sparsely backfills Guest track state from the frozen columns")
    func sparseGuestBackfill() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v11")
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO track (filePath, title, isFavourite) VALUES (?, ?, 1)",
                arguments: ["/Music/fav.flac", "Fav"]
            )
            try db.execute(
                sql: "INSERT INTO track (filePath, title, playCount) VALUES (?, ?, 7)",
                arguments: ["/Music/played.flac", "Played"]
            )
            try db.execute(
                sql: "INSERT INTO track (filePath, title) VALUES (?, ?)",
                arguments: ["/Music/plain.flac", "Plain"]
            )
        }

        try AppDatabase.migrator.migrate(queue)

        try queue.read { db in
            let stateRows = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM profileTrackState") ?? -1
            #expect(stateRows == 2)

            let favFlag = try Int.fetchOne(db, sql: Self.stateColumn("isFavourite"), arguments: ["/Music/fav.flac"])
            #expect(favFlag == 1)

            let playCount = try Int.fetchOne(db, sql: Self.stateColumn("playCount"), arguments: ["/Music/played.flac"])
            #expect(playCount == 7)

            let ownerId = try Int.fetchOne(db, sql: Self.stateColumn("profileId"), arguments: ["/Music/played.flac"])
            #expect(ownerId == 1)

            let untouched = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM profileTrackState pts
                JOIN track t ON t.id = pts.trackId WHERE t.filePath = ?
                """,
                arguments: ["/Music/plain.flac"]
            ) ?? -1
            #expect(untouched == 0)
        }
    }

    @Test("v11→v12 seeds the Guest profile and backfills every playlist to it")
    func guestProfileAndPlaylistBackfill() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v11")
        try queue.write { db in
            for index in 0 ..< 4 {
                try db.execute(sql: "INSERT INTO playlist (name) VALUES (?)", arguments: ["List \(index)"])
            }
        }

        try AppDatabase.migrator.migrate(queue)

        try queue.read { db in
            let guestName = try String.fetchOne(db, sql: "SELECT name FROM profile WHERE id = 1")
            #expect(guestName == "Guest")
            let profiles = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM profile") ?? -1
            #expect(profiles == 1)

            let playlists = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlist") ?? -1
            #expect(playlists == 4)
            let guestOwned = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlist WHERE profileId = 1") ?? -1
            #expect(guestOwned == 4)
        }
    }

    @Test("v11→v12 preserves every pre-existing row count")
    func preservesRowCounts() throws {
        let tables = ["artist", "album", "track", "playlist"]
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v11")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO artist (name, sortName) VALUES ('A', 'A')")
            try db.execute(sql: "INSERT INTO album (title, sortTitle) VALUES ('Alb', 'Alb')")
            try db.execute(
                sql: "INSERT INTO track (filePath, title, isFavourite, playCount) VALUES (?, ?, 1, 3)",
                arguments: ["/Music/x.flac", "X"]
            )
            try db.execute(sql: "INSERT INTO playlist (name) VALUES ('P')")
        }

        let before = try queue.read { db in
            try tables.map { try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)") ?? -1 }
        }

        try AppDatabase.migrator.migrate(queue)

        let after = try queue.read { db in
            try tables.map { try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)") ?? -1 }
        }

        #expect(before == [1, 1, 1, 1])
        #expect(after == before)
    }
}
