import Foundation
import GRDB
import Persistence
import Testing

/// Shape and round-trip coverage for the `v16` playlist-intelligence tables.
@Suite("AISchemaTests")
struct AISchemaTests {
    @Test("v16 creates both playlist-intelligence tables")
    func v16CreatesTables() throws {
        let appDB = try AppDatabase.makeEmpty()
        try appDB.writer.read { db in
            for table in ["trackAudioFeature", "generatedPlaylist"] {
                try #expect(db.tableExists(table), "missing table \(table)")
            }
        }
    }

    @Test("v16 creates the range and lookup indexes")
    func v16CreatesIndexes() throws {
        let appDB = try AppDatabase.makeEmpty()
        let expected: [String: [String]] = [
            "trackAudioFeature": ["trackAudioFeature_on_energy", "trackAudioFeature_on_bpm"],
            "generatedPlaylist": ["generatedPlaylist_on_generatorKind"],
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

    /// The whole point of the table's shape: `trackId` is the entire primary key, so
    /// there is no auto-increment `id` a caller could accidentally key a second row by.
    @Test("trackAudioFeature is keyed by trackId alone and cascades from track")
    func trackAudioFeatureIsCallerKeyed() throws {
        let appDB = try AppDatabase.makeEmpty()
        try appDB.writer.read { db in
            let columns = try db.columns(in: "trackAudioFeature").map(\.name)
            #expect(columns == [
                "trackId", "fileSize", "mtime", "bpm",
                "energy", "brightness", "analysisVersion", "computedAt",
            ])
            #expect(!columns.contains("id"))
            try #expect(db.primaryKey("trackAudioFeature").columns == ["trackId"])
            let foreignKeys = try db.foreignKeys(on: "trackAudioFeature")
            #expect(foreignKeys.map(\.destinationTable) == ["track"])
        }
    }

    @Test("a feature row round-trips under its caller-supplied key")
    func trackAudioFeatureRoundTrip() throws {
        let appDB = try AppDatabase.makeEmpty()
        let trackId = try StatsFixtures.seedTrack(appDB, path: "/music/analysed.flac")
        let record = AIFixtures.feature(trackId: trackId)
        try appDB.writer.write { db in try record.insert(db) }

        let stored = try appDB.writer.read { db in
            try TrackAudioFeatureRecord.fetchOne(db, key: trackId)
        }
        #expect(stored == record)
    }

    @Test("a feature row accepts a null bpm when tempo estimation found no beat")
    func trackAudioFeatureAllowsNullBPM() throws {
        let appDB = try AppDatabase.makeEmpty()
        let trackId = try StatsFixtures.seedTrack(appDB, path: "/music/ambient.flac")
        var record = AIFixtures.feature(trackId: trackId)
        record.bpm = nil
        try appDB.writer.write { db in try record.insert(db) }

        let stored = try appDB.writer.read { db in
            try TrackAudioFeatureRecord.fetchOne(db, key: trackId)
        }
        #expect(stored?.bpm == nil)
    }

    @Test("deleting a track discards its derived features")
    func trackAudioFeatureCascades() throws {
        let appDB = try AppDatabase.makeEmpty()
        let trackId = try StatsFixtures.seedTrack(appDB, path: "/music/doomed.flac")
        try appDB.writer.write { db in
            try AIFixtures.feature(trackId: trackId).insert(db)
            _ = try TrackRecord.deleteOne(db, key: trackId)
        }

        let remaining = try appDB.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM trackAudioFeature") ?? -1
        }
        #expect(remaining == 0)
    }

    @Test("a generated-playlist row round-trips and writes its rowid back")
    func generatedPlaylistRoundTrip() throws {
        let appDB = try AppDatabase.makeEmpty()
        let playlistId = try AIFixtures.seedPlaylist(appDB, name: "Morning Mix")
        var record = AIFixtures.generated(playlistId: playlistId)
        try appDB.writer.write { db in try record.insert(db) }
        let recordId = try #require(record.id)

        let stored = try appDB.writer.read { db in
            try GeneratedPlaylistRecord.fetchOne(db, key: recordId)
        }
        #expect(stored == record)
        #expect(stored?.lastRefreshedAt == nil)
    }

    @Test("at most one generated-playlist row may exist per playlist")
    func generatedPlaylistIsUniquePerPlaylist() throws {
        let appDB = try AppDatabase.makeEmpty()
        let playlistId = try AIFixtures.seedPlaylist(appDB, name: "Rediscovery")
        try appDB.writer.write { db in
            var first = AIFixtures.generated(playlistId: playlistId)
            try first.insert(db)
        }

        #expect(throws: (any Error).self) {
            try appDB.writer.write { db in
                var duplicate = AIFixtures.generated(playlistId: playlistId, kind: "assistant")
                try duplicate.insert(db)
            }
        }
    }
}
