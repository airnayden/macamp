import Foundation
import GRDB
import Persistence

/// Seeds for the `v20` guarded `track` rebuild.
enum CueTrackFixtures {
    static let trackID: Int64 = 42
    static let otherTrackID: Int64 = 43
    static let playlistID: Int64 = 7
    static let trackPath = "/music/seeded.flac"
    static let trackTitle = "Comfortably Numb"
    static let seedMtime = 1_700_000_000.0

    /// The five tables whose foreign key to `track` CASCADES on delete, so an
    /// `.immediate` v20 would empty every one of them when `track` is dropped.
    static let cascadingChildTables = [
        "playlistTrack", "trackAudioFeature", "profileTrackState",
        "folderTrackOrder", "trackLoudness",
    ]

    /// The two stats tables whose `trackId` is a BARE integer with no foreign key,
    /// so they survive by orphan-tolerance rather than by referential integrity.
    static let bareTrackIDTables = ["playEvent", "playSegmentHeat"]

    /// A `v19` database with one row in every table the rebuild could destroy.
    ///
    /// Seeded at v19 rather than v17 on purpose: `trackLoudness` does not exist
    /// until v18, and a fixture that cannot populate it cannot prove its rows
    /// survive. Raw SQL keeps the seed decoupled from the current record shapes,
    /// matching the other pre-migration seeds in this target.
    static func seededV19Queue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v19")
        try queue.write { db in
            try seedTracks(db)
            try seedChildren(db)
        }
        return queue
    }

    private static func seedTracks(_ db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO track (id, filePath, title, artistName, albumTitle, fileSize, mtime)
            VALUES (?, ?, ?, 'Pink Floyd', 'The Wall', 1024, ?)
            """,
            arguments: [trackID, trackPath, trackTitle, seedMtime]
        )
        try db.execute(
            sql: """
            INSERT INTO track (id, filePath, title, artistName, albumTitle)
            VALUES (?, '/music/other.flac', 'Hey You', 'Pink Floyd', 'The Wall')
            """,
            arguments: [otherTrackID]
        )
        try db.execute(sql: "INSERT INTO libraryRoot (profileId, path) VALUES (1, '/music')")
    }

    private static func seedChildren(_ db: Database) throws {
        try seedCascadingChildren(db)
        try seedBareTrackIDStats(db)
    }

    private static func seedCascadingChildren(_ db: Database) throws {
        try db.execute(
            sql: "INSERT INTO playlist (id, name, profileId) VALUES (?, 'Seeded List', 1)",
            arguments: [playlistID]
        )
        try db.execute(
            sql: "INSERT INTO playlistTrack (playlistId, trackId, position) VALUES (?, ?, 0)",
            arguments: [playlistID, trackID]
        )
        try db.execute(
            sql: "INSERT INTO playlistTrack (playlistId, trackId, position) VALUES (?, ?, 1)",
            arguments: [playlistID, otherTrackID]
        )
        try db.execute(
            sql: """
            INSERT INTO profileTrackState (profileId, trackId, isFavourite, playCount)
            VALUES (1, ?, 1, 9)
            """,
            arguments: [trackID]
        )
        try db.execute(
            sql: """
            INSERT INTO trackAudioFeature
                (trackId, fileSize, mtime, bpm, energy, brightness, analysisVersion, computedAt)
            VALUES (?, 1024, ?, 120.0, 0.5, 0.4, 1, ?)
            """,
            arguments: [trackID, seedMtime, seedMtime]
        )
        try db.execute(
            sql: "INSERT INTO folderTrackOrder (profileId, rootPath, trackId, position) VALUES (1, '/music', ?, 0)",
            arguments: [trackID]
        )
        try db.execute(
            sql: """
            INSERT INTO trackLoudness
                (trackId, integratedLUFS, truePeak, analysisVersion, fileSize, mtime, computedAt)
            VALUES (?, -14.5, 0.98, 1, 1024, ?, ?)
            """,
            arguments: [trackID, seedMtime, seedMtime]
        )
    }

    private static func seedBareTrackIDStats(_ db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO playEvent (profileId, trackId, artistName, title, startedAt, utcOffsetSeconds)
            VALUES (1, ?, 'Pink Floyd', ?, ?, 7200)
            """,
            arguments: [trackID, trackTitle, seedMtime]
        )
        try db.execute(
            sql: """
            INSERT INTO playSegmentHeat
                (profileId, trackId, title, durationSeconds, bucketCounts, totalPasses, updatedAt)
            VALUES (1, ?, ?, 382.0, ?, 3, ?)
            """,
            arguments: [trackID, trackTitle, Data(count: 400), seedMtime]
        )
    }

    /// Row counts for `tables`, in the order given.
    static func rowCounts(_ db: Database, tables: [String]) throws -> [Int] {
        try tables.map { try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\($0)\"") ?? -1 }
    }

    /// Track ids the FTS5 index returns for `pattern`, through the external-content
    /// `rowid` — which is what proves the index is still wired to `track`.
    static func searchRowIDs(_ db: Database, matching pattern: String) throws -> [Int64] {
        try Int64.fetchAll(
            db,
            sql: "SELECT rowid FROM trackSearch WHERE trackSearch MATCH ? ORDER BY rowid",
            arguments: [pattern]
        )
    }
}
