import Foundation
import GRDB
import Persistence
import Testing

/// Shape and forward-migration coverage for the `v17` `downloadHistory` table.
@Suite("DownloadHistorySchemaTests")
struct DownloadHistorySchemaTests {
    @Test("v17 creates downloadHistory with its two lookup indexes")
    func v17CreatesTableAndIndexes() throws {
        let appDB = try AppDatabase.makeEmpty()
        try appDB.writer.read { db in
            try #expect(db.tableExists("downloadHistory"))
            let indexes = try db.indexes(on: "downloadHistory").map(\.name)
            #expect(indexes.contains("downloadHistory_on_canonicalVideoID"))
            #expect(indexes.contains("downloadHistory_on_downloadedAt"))
        }
    }

    /// The survivability claim, asserted structurally rather than by comment: an entry
    /// must outlive the file it names and the library row that file may never have
    /// become, so nothing may cascade into it.
    @Test("downloadHistory declares no foreign keys at all")
    func downloadHistoryHasNoForeignKeys() throws {
        let appDB = try AppDatabase.makeEmpty()
        try appDB.writer.read { db in
            let destinations = try db.foreignKeys(on: "downloadHistory").map(\.destinationTable)
            #expect(destinations.isEmpty, "downloadHistory must not reference \(destinations)")
        }
    }

    @Test("downloadHistory keys on a TEXT id and keeps successful and failed attempts")
    func downloadHistoryColumnShape() throws {
        let appDB = try AppDatabase.makeEmpty()
        try appDB.writer.read { db in
            let columns = try db.columns(in: "downloadHistory")
            let primary = try #require(columns.first { $0.primaryKeyIndex == 1 })
            #expect(primary.name == "id")
            #expect(primary.type.uppercased() == "TEXT")

            let required = Set(columns.filter(\.isNotNull).map(\.name))
            #expect(required == [
                "id", "canonicalVideoID", "filePath",
                "audioFormat", "audioQuality", "sourceURL",
                "downloadedAt", "utcOffsetSeconds",
            ])
            let optional = Set(columns.filter { !$0.isNotNull }.map(\.name))
            #expect(optional == ["title", "uploader", "durationSeconds", "failureReason"])
        }
    }

    @Test("v21 preserves a successful entry created under v20")
    func v21PreservesExistingSuccessfulEntry() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v20")
        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO downloadHistory
                (id, canonicalVideoID, filePath, audioFormat, audioQuality,
                 sourceURL, downloadedAt, utcOffsetSeconds)
            VALUES ('legacy', 'dQw4w9WgXcQ', '/music/legacy.m4a', 'm4a', 'best',
                    'https://www.youtube.com/watch?v=dQw4w9WgXcQ', 100, 0)
            """)
        }

        try AppDatabase.migrator.migrate(queue)

        try queue.read { db in
            let stored = try DownloadHistoryRecord.fetchOne(db, key: "legacy")
            let entry = try #require(stored)
            #expect(entry.filePath == "/music/legacy.m4a")
            #expect(entry.failureReason == nil)
        }
    }

    @Test("a history row round-trips every captured field")
    func roundTripsEveryField() throws {
        let appDB = try AppDatabase.makeEmpty()
        let entry = DownloadHistoryFixtures.entry(
            id: "8B0B8C8E-0000-0000-0000-00000000FACE",
            videoID: "dQw4w9WgXcQ",
            downloadedAt: 1_700_000_000
        )
        try appDB.writer.write { db in try entry.insert(db) }

        let stored = try appDB.writer.read { db in
            try DownloadHistoryRecord.fetchOne(db, key: entry.id)
        }
        #expect(stored == entry)
        #expect(stored?.utcOffsetSeconds == 7200)
        #expect(stored?.audioFormat == "m4a")
        #expect(stored?.audioQuality == "best")
    }

    @Test("title, uploader and duration are optional")
    func acceptsMissingOptionalMetadata() throws {
        let appDB = try AppDatabase.makeEmpty()
        var entry = DownloadHistoryFixtures.entry(id: "bare", videoID: "vid", downloadedAt: 1)
        entry.title = nil
        entry.uploader = nil
        entry.durationSeconds = nil
        try appDB.writer.write { db in try entry.insert(db) }

        let stored = try appDB.writer.read { db in
            try DownloadHistoryRecord.fetchOne(db, key: "bare")
        }
        #expect(stored?.title == nil)
        #expect(stored?.uploader == nil)
        #expect(stored?.durationSeconds == nil)
    }

    /// Deleting the library row a download became must leave its history untouched —
    /// the same claim `StatsSchemaTests` makes for `playEvent`, restated here because
    /// the absent foreign key is what a future "tidy-up" migration would remove.
    @Test("deleting a track leaves its download history standing")
    func deletingATrackKeepsHistory() throws {
        let appDB = try AppDatabase.makeEmpty()
        try appDB.writer.write { db in
            try db.execute(
                sql: "INSERT INTO track (id, filePath, title) VALUES (?, ?, ?)",
                arguments: [99, "/music/taken.m4a", "Taken"]
            )
            var entry = DownloadHistoryFixtures.entry(id: "keep", videoID: "vid", downloadedAt: 5)
            entry.filePath = "/music/taken.m4a"
            try entry.insert(db)
            try db.execute(sql: "DELETE FROM track WHERE id = 99")
        }

        let survivors = try appDB.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM downloadHistory") ?? -1
        }
        #expect(survivors == 1)
    }

    @Test("v16→head lands the ledger on v21 and creates the table")
    func migratesV16ToHead() throws {
        let queue = try DownloadHistoryFixtures.seededV16Queue()
        let existsBefore = try queue.read { db in try db.tableExists("downloadHistory") }
        #expect(!existsBefore)

        try AppDatabase.migrator.migrate(queue)

        try queue.read { db in
            try #expect(db.tableExists("downloadHistory"))
            try #expect(AppDatabase.migrator.appliedMigrations(db).last == "v21")
        }
    }

    /// The failure scenario: a v16 database carried forward must come out the other
    /// side with **every pre-existing row byte-identical**. The digest covers every
    /// user table in the database, not just the ones this fixture seeds, so a migration
    /// that dropped, rewrote or re-indexed anything at all would fail here.
    ///
    /// The seeded-content assertions are not decoration — they prove the digest is
    /// non-empty before it is compared, so "unchanged" cannot be satisfied by a digest
    /// that measured nothing.
    ///
    /// Every table a post-v16 migration ADDS is carved out and asserted empty, so the
    /// carve-out list doubles as the record of what each one contributed.
    ///
    /// v20 is the one migration that is NOT carved out: it rebuilds `track` instead of
    /// adding a table, so the digest projects `track` onto its v19 columns on both
    /// sides and the row still has to survive byte-for-byte, rowid included.
    @Test("v16→head leaves every pre-existing row byte-identical")
    func migratesV16ToHeadByteStably() throws {
        let queue = try DownloadHistoryFixtures.seededV16Queue()
        let before = try queue.read { db in try DownloadHistoryFixtures.trackProjectedDigest(db) }
        #expect(before["track"]?.count == 1)
        #expect(before["playEvent"]?.count == 1)
        #expect(before["trackAudioFeature"]?.count == 1)
        #expect(before["lyricsCache"]?.count == 1)
        #expect(before["trackSearch"]?.count == 1, "the FTS5 index must be in the digest")
        #expect(before.count >= 25, "digest covered only \(before.count) tables")

        try AppDatabase.migrator.migrate(queue)

        let after = try queue.read { db in try DownloadHistoryFixtures.trackProjectedDigest(db) }
        #expect(after["downloadHistory"] == [], "v17 must add the table empty")
        #expect(after["trackLoudness"] == [], "v18 must add the table empty")
        #expect(after["parametricEQPreset"] == [], "v19 must add the table empty")
        try queue.read { db in
            try #expect(DownloadHistoryFixtures.nonCueTrackCount(db) == 1, "v20 must default the cue columns")
        }
        var carried = after
        carried["downloadHistory"] = nil
        carried["trackLoudness"] = nil
        carried["parametricEQPreset"] = nil
        #expect(carried == before)
    }

    @Test("v16→head keeps the seeded rows readable through their records")
    func migratesV16ToHeadLosslessly() throws {
        let queue = try DownloadHistoryFixtures.seededV16Queue()

        try AppDatabase.migrator.migrate(queue)

        try queue.read { db in
            let path = try String.fetchOne(db, sql: "SELECT filePath FROM track WHERE id = 42")
            #expect(path == "/music/seeded.flac")
            let title = try String.fetchOne(db, sql: "SELECT title FROM playEvent WHERE trackId = 42")
            #expect(title == "Seeded")
            let feature = try TrackAudioFeatureRecord.fetchOne(db, key: 42)
            #expect(feature?.energy == 0.5)
            #expect(feature?.analysisVersion == 1)
        }
    }
}
