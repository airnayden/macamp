import Foundation
import GRDB
import Persistence
import Testing

/// Shape and forward-migration coverage for the `v18` `trackLoudness` table.
@Suite("TrackLoudnessSchemaTests")
struct TrackLoudnessSchemaTests {
    @Test("v18 creates trackLoudness keyed on trackId alone")
    func v18CreatesTable() throws {
        let appDB = try AppDatabase.makeEmpty()
        try appDB.writer.read { db in
            try #expect(db.tableExists("trackLoudness"))
            let columns = try db.columns(in: "trackLoudness")
            let primaryKeyed = columns.filter { $0.primaryKeyIndex > 0 }.map(\.name)
            #expect(primaryKeyed == ["trackId"], "the caller-keyed PK must be trackId alone")
            #expect(!columns.contains { $0.name == "id" }, "no auto-increment id column")
        }
    }

    /// The primary key is partitioned out because SQLite reports an
    /// `INTEGER PRIMARY KEY` — a rowid alias — as `notnull = 0` even though it can
    /// never hold NULL. `trackAudioFeature.trackId` reads exactly the same way, which
    /// the last assertion pins: this is the pragma's quirk, not a schema difference.
    @Test("trackLoudness declares the nullable and non-null columns the analyser needs")
    func columnNullability() throws {
        let appDB = try AppDatabase.makeEmpty()
        try appDB.writer.read { db in
            let all = try db.columns(in: "trackLoudness")
            let columns = all.filter { $0.primaryKeyIndex == 0 }
            #expect(Set(columns.filter(\.isNotNull).map(\.name)) == [
                "truePeak", "analysisVersion",
                "fileSize", "mtime", "cueStartFrame", "computedAt",
            ])
            #expect(Set(columns.filter { !$0.isNotNull }.map(\.name)) == [
                "integratedLUFS", "albumLUFS", "albumPeak",
                "blockPowersHistogram", "cueEndFrame",
            ])

            let rowidAlias = try #require(all.first { $0.name == "trackId" })
            let feature = try #require(try db.columns(in: "trackAudioFeature")
                .first { $0.name == "trackId" })
            #expect(rowidAlias.isNotNull == feature.isNotNull)
        }
    }

    @Test("cueStartFrame defaults to the -1 whole-file sentinel")
    func cueStartFrameSentinelDefault() throws {
        let appDB = try AppDatabase.makeEmpty()
        try appDB.writer.write { db in
            try db.execute(sql: "INSERT INTO track (id, filePath) VALUES (1, '/a.flac')")
            try db.execute(sql: """
            INSERT INTO trackLoudness
                (trackId, truePeak, analysisVersion, fileSize, mtime, computedAt)
            VALUES (1, 0.5, 1, 1024, 1.0, 2.0)
            """)
        }
        let stored = try appDB.writer.read { db in try TrackLoudnessRecord.fetchOne(db, key: 1) }
        #expect(stored?.cueStartFrame == TrackLoudnessFingerprint.wholeFileCueStartFrame)
        #expect(stored?.cueEndFrame == nil)
        #expect(stored?.fingerprint.isWholeFile == true)
    }

    /// Loudness is derived from the file, so — unlike `playEvent` — the row has no
    /// survivability duty and must go with the track it describes.
    @Test("deleting a track cascades its loudness row away")
    func deletingATrackCascades() throws {
        let appDB = try AppDatabase.makeEmpty()
        try appDB.writer.write { db in
            try db.execute(sql: "INSERT INTO track (id, filePath) VALUES (9, '/gone.flac')")
            try TrackLoudnessFixtures.record(trackId: 9).insert(db)
            try db.execute(sql: "DELETE FROM track WHERE id = 9")
        }
        let survivors = try appDB.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM trackLoudness") ?? -1
        }
        #expect(survivors == 0)
    }

    @Test("a loudness row round-trips every field, histogram included")
    func roundTripsEveryField() throws {
        let appDB = try AppDatabase.makeEmpty()
        let histogram = try TrackLoudnessFixtures.histogram(bin: 300, count: 7)
        let record = TrackLoudnessFixtures.record(
            trackId: 5,
            integratedLUFS: -13.25,
            truePeak: 1.02,
            albumLUFS: -12.0,
            albumPeak: 1.1,
            histogram: histogram,
            fingerprint: TrackLoudnessFixtures.fingerprint(cueStartFrame: 588, cueEndFrame: 176_400)
        )
        try appDB.writer.write { db in
            try db.execute(sql: "INSERT INTO track (id, filePath) VALUES (5, '/cue.flac')")
            try record.insert(db)
        }

        let stored = try appDB.writer.read { db in try TrackLoudnessRecord.fetchOne(db, key: 5) }
        #expect(stored == record)
        let decoded = try #require(try stored?.decodedHistogram())
        #expect(decoded[300] == 7)
        #expect(stored?.fingerprint.isWholeFile == false)
    }

    /// `nil` integrated loudness is the silence sentinel from `LoudnessMeasurement`,
    /// not a missing value — storing `0` instead would assert a reference level that
    /// does not exist.
    @Test("integratedLUFS accepts the nil silence sentinel")
    func acceptsSilenceSentinel() throws {
        let appDB = try AppDatabase.makeEmpty()
        try appDB.writer.write { db in
            try db.execute(sql: "INSERT INTO track (id, filePath) VALUES (3, '/silent.flac')")
            try TrackLoudnessFixtures.record(trackId: 3, integratedLUFS: nil, truePeak: 0).insert(db)
        }
        let stored = try appDB.writer.read { db in try TrackLoudnessRecord.fetchOne(db, key: 3) }
        #expect(stored?.integratedLUFS == nil)
        #expect(stored?.truePeak == 0)
    }

    /// The failure path: re-analysing a changed file must overwrite in place. A second
    /// `insert` is asserted to throw first, so "one row" cannot be satisfied by a table
    /// that quietly accepted a duplicate primary key.
    @Test("a second insert for one trackId conflicts, and upsert replaces it")
    func duplicateInsertUpsertsToOneRow() throws {
        let appDB = try AppDatabase.makeEmpty()
        try appDB.writer.write { db in
            try db.execute(sql: "INSERT INTO track (id, filePath) VALUES (1, '/a.flac')")
            try TrackLoudnessFixtures.record(trackId: 1, integratedLUFS: -20).insert(db)
        }

        #expect(throws: (any Error).self) {
            try appDB.writer.write { db in
                try TrackLoudnessFixtures.record(trackId: 1, integratedLUFS: -9).insert(db)
            }
        }

        try appDB.writer.write { db in
            try TrackLoudnessFixtures.record(
                trackId: 1,
                integratedLUFS: -9,
                fingerprint: TrackLoudnessFixtures.fingerprint(fileSize: 2048, mtime: 42)
            ).upsert(db)
        }

        try appDB.writer.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM trackLoudness") ?? -1
            #expect(count == 1)
            let stored = try TrackLoudnessRecord.fetchOne(db, key: 1)
            #expect(stored?.integratedLUFS == -9)
            #expect(stored?.fingerprint == TrackLoudnessFixtures.fingerprint(fileSize: 2048, mtime: 42))
        }
    }

    /// `willSave` is the last gate before the database, so a misaligned histogram is
    /// refused whichever write path a caller takes.
    @Test("a wrong-length histogram blob is refused on save")
    func refusesMisalignedHistogram() throws {
        let appDB = try AppDatabase.makeEmpty()
        try appDB.writer.write { db in
            try db.execute(sql: "INSERT INTO track (id, filePath) VALUES (1, '/a.flac')")
        }
        #expect(throws: BlockLoudnessHistogramError.self) {
            try appDB.writer.write { db in
                try TrackLoudnessFixtures.record(trackId: 1, histogram: Data(count: 8)).insert(db)
            }
        }
    }

    @Test("v17→head lands the ledger on v21 and adds the table empty")
    func migratesV17ToHead() throws {
        let queue = try TrackLoudnessFixtures.seededV17Queue()
        let existsBefore = try queue.read { db in try db.tableExists("trackLoudness") }
        #expect(!existsBefore)

        try AppDatabase.migrator.migrate(queue)

        try queue.read { db in
            try #expect(db.tableExists("trackLoudness"))
            try #expect(AppDatabase.migrator.appliedMigrations(db).last == "v21")
            let rows = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM trackLoudness") ?? -1
            #expect(rows == 0)
        }
    }

    /// The failure scenario: a v17 database carried forward must keep **every**
    /// pre-existing row byte-identical. The digest covers every user table, so a v18
    /// that dropped, rewrote or re-indexed anything would fail here. The seeded-content
    /// assertions prove the digest is non-empty before it is compared.
    ///
    /// v20 rebuilds `track` rather than adding a table, so the digest projects `track`
    /// onto its v19 columns on both sides — the row, its values and its rowid still
    /// have to come through the rebuild untouched.
    @Test("v17→head leaves every pre-existing row byte-identical")
    func migratesV17ToHeadByteStably() throws {
        let queue = try TrackLoudnessFixtures.seededV17Queue()
        let before = try queue.read { db in try DownloadHistoryFixtures.trackProjectedDigest(db) }
        #expect(before["track"]?.count == 1)
        #expect(before["downloadHistory"]?.count == 1)
        #expect(before["trackAudioFeature"]?.count == 1)
        #expect(before["trackSearch"]?.count == 1, "the FTS5 index must be in the digest")
        #expect(before.count >= 26, "digest covered only \(before.count) tables")

        try AppDatabase.migrator.migrate(queue)

        let after = try queue.read { db in try DownloadHistoryFixtures.trackProjectedDigest(db) }
        #expect(after["trackLoudness"] == [], "v18 must add the table empty")
        #expect(after["parametricEQPreset"] == [], "v19 must add the table empty")
        try queue.read { db in
            try #expect(DownloadHistoryFixtures.nonCueTrackCount(db) == 1, "v20 must default the cue columns")
        }
        var carried = after
        carried["trackLoudness"] = nil
        carried["parametricEQPreset"] = nil
        #expect(carried == before)
    }

    @Test("v17→head keeps the seeded rows readable through their records")
    func migratesV17ToHeadLosslessly() throws {
        let queue = try TrackLoudnessFixtures.seededV17Queue()

        try AppDatabase.migrator.migrate(queue)

        try queue.read { db in
            let path = try String.fetchOne(db, sql: "SELECT filePath FROM track WHERE id = 42")
            #expect(path == "/music/seeded.flac")
            let feature = try TrackAudioFeatureRecord.fetchOne(db, key: 42)
            #expect(feature?.energy == 0.5)
            let history = try DownloadHistoryRecord.fetchOne(db, key: "seeded")
            #expect(history?.canonicalVideoID == "vid")
        }
    }
}
