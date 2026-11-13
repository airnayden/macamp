import Foundation
import GRDB
import Persistence

/// Shared seeds and probes for the `v17` download-history suites.
enum DownloadHistoryFixtures {
    static func entry(
        id: String,
        videoID: String,
        downloadedAt: TimeInterval,
        audioFormat: String = "m4a",
        audioQuality: String = "best"
    ) -> DownloadHistoryRecord {
        DownloadHistoryRecord(
            id: id,
            canonicalVideoID: videoID,
            title: "Title \(videoID)",
            uploader: "Uploader \(videoID)",
            durationSeconds: 212.5,
            filePath: "/Users/listener/Music/\(videoID).\(audioFormat)",
            audioFormat: audioFormat,
            audioQuality: audioQuality,
            sourceURL: "https://www.youtube.com/watch?v=\(videoID)",
            downloadedAt: downloadedAt,
            utcOffsetSeconds: 7200
        )
    }

    /// A `v16` database holding one row in each of eight tables spanning v1 → v16.
    ///
    /// Raw SQL keeps the seed decoupled from the current record shapes, matching the
    /// other pre-migration seeds in this target.
    static func seededV16Queue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v16")
        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO track (id, filePath, title, artistName, albumTitle)
            VALUES (42, '/music/seeded.flac', 'Seeded', 'Pink Floyd', 'Animals')
            """)
            try db.execute(sql: "INSERT INTO playlist (id, name, profileId) VALUES (7, 'Seeded List', 1)")
            try db.execute(
                sql: "INSERT INTO smartPlaylist (playlistId, rulesJson) VALUES (?, ?)",
                arguments: [7, #"{"limit":50}"#]
            )
            try db.execute(sql: """
            INSERT INTO playEvent
                (profileId, trackId, artistName, title, startedAt, utcOffsetSeconds)
            VALUES (1, 42, 'Pink Floyd', 'Seeded', 1700000000.0, 7200)
            """)
            try db.execute(sql: """
            INSERT INTO trackAudioFeature
                (trackId, fileSize, mtime, bpm, energy, brightness, analysisVersion, computedAt)
            VALUES (42, 1024, 1700000000.0, 120.0, 0.5, 0.4, 1, 1700000000.0)
            """)
            try db.execute(sql: """
            INSERT INTO generatedPlaylist (playlistId, generatorKind, specJson, specVersion)
            VALUES (7, 'daypart', '{}', 1)
            """)
            try db.execute(sql: """
            INSERT INTO lyricsCache (cacheKey, source, payloadJson, fetchedAt)
            VALUES ('/music/seeded.flac', 'embedded', '{}', 1700000000.0)
            """)
            try db.execute(sql: "INSERT INTO eqPreset (name, bandGainsJson) VALUES ('Rock', '[]')")
        }
        return queue
    }

    /// Every user table's contents, rendered to sorted row descriptions.
    ///
    /// Sorting makes the digest order-independent (so it compares CONTENT, not fetch
    /// order) while keeping it sensitive to any changed, added or dropped value. The
    /// migration ledger is excluded because it legitimately gains a row; everything
    /// else — including the FTS5 index and its shadow tables — must be identical
    /// across a migration that only adds a table.
    static func databaseDigest(_ db: Database) throws -> [String: [String]] {
        let tables = try String.fetchAll(db, sql: """
        SELECT name FROM sqlite_master
        WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name <> 'grdb_migrations'
        ORDER BY name
        """)
        var digest: [String: [String]] = [:]
        for table in tables {
            // Compare the original download history columns across v21.
            let projection = table == "downloadHistory"
                ? """
                id, canonicalVideoID, title, uploader, durationSeconds, filePath,
                audioFormat, audioQuality, sourceURL, downloadedAt, utcOffsetSeconds
                """
                : "*"
            let rows = try Row.fetchAll(db, sql: "SELECT \(projection) FROM \"\(table)\"")
            digest[table] = rows.map(\.description).sorted()
        }
        return digest
    }

    /// Every `track` column that exists at v19, in physical order.
    static let v19TrackColumns = """
    id, filePath, title, sortTitle, artistName, albumTitle, artistId, albumId,
    trackNumber, discNumber, duration, bitrate, sampleRate, bitDepth, fileSize,
    mtime, availability, dateAdded, playCount, replaygainTrackGain,
    replaygainTrackPeak, replaygainAlbumGain, replaygainAlbumPeak, genre,
    albumArtist, composer, year, channelCount, customPosition, isFavourite,
    listenedCount
    """

    /// ``databaseDigest(_:)`` with `track` projected onto its v19 columns.
    ///
    /// v20 REBUILDS `track` rather than adding a table, appending four cue columns,
    /// so `SELECT *` on it legitimately differs across the migration while every
    /// value that existed beforehand must not. Projecting is not a carve-out and is
    /// strictly stronger than nil-ing the key out: a rebuild that dropped a row,
    /// altered a value or minted a fresh rowid still fails the comparison. Applied
    /// to BOTH sides — on a pre-v20 database the projection selects the whole table,
    /// so a drifted list raises "no such column" instead of passing quietly.
    static func trackProjectedDigest(_ db: Database) throws -> [String: [String]] {
        var digest = try databaseDigest(db)
        digest["track"] = try Row
            .fetchAll(db, sql: "SELECT \(v19TrackColumns) FROM track")
            .map(\.description)
            .sorted()
        return digest
    }

    /// The cue columns every carried-forward row must hold after v20: the
    /// `-1` whole-file sentinel, no sheet, no end bound, not suppressed.
    static func nonCueTrackCount(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: """
        SELECT COUNT(*) FROM track
        WHERE cueSheetPath IS NULL AND cueStartFrame = -1
          AND cueEndFrame IS NULL AND cueSuppressed = 0
        """) ?? -1
    }
}

/// Every SQL statement a traced connection executed, in execution order.
///
/// Exists so "this costs exactly one statement" can be a measurement rather than a
/// reading of the implementation: a version that looked ids up one at a time would
/// record N entries here and fail.
final class SQLTraceLog: @unchecked Sendable {
    private let lock = NSLock()
    private var statements: [String] = []

    func record(_ sql: String) {
        lock.lock()
        defer { lock.unlock() }
        statements.append(sql)
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return statements
    }

    func mentioning(_ needle: String) -> [String] {
        all.filter { $0.contains(needle) }
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        statements.removeAll()
    }
}

extension DownloadHistoryFixtures {
    /// A migrated database whose every statement is recorded.
    static func tracedQueue() throws -> (queue: DatabaseQueue, trace: SQLTraceLog) {
        let trace = SQLTraceLog()
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            db.trace { event in trace.record("\(event)") }
        }
        let queue = try DatabaseQueue(configuration: configuration)
        try AppDatabase.migrator.migrate(queue)
        return (queue, trace)
    }
}
