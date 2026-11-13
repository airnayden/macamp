import Foundation
import GRDB
import Persistence
import Testing

extension AppDatabaseTests {
    /// v20 replaced the v1 column-level `UNIQUE` on `filePath` with a table-level
    /// `UNIQUE(filePath, cueStartFrame)`, because one audio file legitimately backs
    /// many cue segments. The pair is asserted in BOTH directions: a second whole-file
    /// row for the same path is still refused (both default to the `-1` sentinel, so
    /// the pair collides), while two segments of that same file insert happily.
    @Test("track (filePath, cueStartFrame) is UNIQUE, filePath alone is not")
    func filePathAndCueStartFrameUnique() throws {
        let appDB = try AppDatabase.makeEmpty()
        try appDB.writer.write { db in
            try db.execute(
                sql: "INSERT INTO track (filePath, cueStartFrame) VALUES (?, ?)",
                arguments: ["/album.flac", 0]
            )
            try db.execute(
                sql: "INSERT INTO track (filePath, cueStartFrame) VALUES (?, ?)",
                arguments: ["/album.flac", 13230]
            )
        }
        let segments = try appDB.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track WHERE filePath = '/album.flac'") ?? -1
        }
        #expect(segments == 2, "one audio file must be able to back many cue segments")
    }

    @Test("track rejects a duplicate whole-file row for one filePath")
    func wholeFileDuplicateRejected() throws {
        let appDB = try AppDatabase.makeEmpty()
        var original = TrackRecord(filePath: "/dup.flac")
        var duplicate = TrackRecord(filePath: "/dup.flac")
        try appDB.writer.write { try original.insert($0) }
        #expect(throws: DatabaseError.self) {
            try appDB.writer.write { try duplicate.insert($0) }
        }
    }

    @Test("track.availability CHECK rejects invalid raw values")
    func availabilityCheck() throws {
        let appDB = try AppDatabase.makeEmpty()
        #expect(throws: DatabaseError.self) {
            try appDB.writer.write { db in
                try db.execute(
                    sql: "INSERT INTO track (filePath, availability) VALUES (?, ?)",
                    arguments: ["/bad.flac", "bogus"]
                )
            }
        }
    }

    @Test("playlistTrack (playlistId, position) is UNIQUE")
    func playlistPositionUnique() throws {
        let appDB = try AppDatabase.makeEmpty()
        var playlist = PlaylistRecord(name: "P")
        var trackOne = TrackRecord(filePath: "/1.flac")
        var trackTwo = TrackRecord(filePath: "/2.flac")
        try appDB.writer.write { db in
            try playlist.insert(db)
            try trackOne.insert(db)
            try trackTwo.insert(db)
            let playlistID = try #require(playlist.id)
            let trackOneID = try #require(trackOne.id)
            var first = PlaylistTrackRecord(playlistId: playlistID, trackId: trackOneID, position: 0)
            try first.insert(db)
        }
        let playlistID = try #require(playlist.id)
        let trackTwoID = try #require(trackTwo.id)
        var clash = PlaylistTrackRecord(playlistId: playlistID, trackId: trackTwoID, position: 0)
        #expect(throws: DatabaseError.self) {
            try appDB.writer.write { try clash.insert($0) }
        }
    }

    @Test("deleting a playlist cascades to its playlistTrack rows")
    func cascadeDeletePlaylist() throws {
        let appDB = try AppDatabase.makeEmpty()
        var playlist = PlaylistRecord(name: "P")
        var track = TrackRecord(filePath: "/c.flac")
        try appDB.writer.write { db in
            try playlist.insert(db)
            try track.insert(db)
            let playlistID = try #require(playlist.id)
            let trackID = try #require(track.id)
            var entry = PlaylistTrackRecord(playlistId: playlistID, trackId: trackID, position: 0)
            try entry.insert(db)
        }
        let deleted = try appDB.writer.write { try playlist.delete($0) }
        #expect(deleted)
        try appDB.writer.read { db in
            try #expect(PlaylistTrackRecord.fetchCount(db) == 0)
            try #expect(TrackRecord.fetchCount(db) == 1)
        }
    }

    @Test("deleting an artist nullifies dependent foreign keys")
    func setNullOnArtistDelete() throws {
        let appDB = try AppDatabase.makeEmpty()
        var artist = ArtistRecord(name: "A", sortName: "A")
        var track = TrackRecord(filePath: "/n.flac")
        try appDB.writer.write { db in
            try artist.insert(db)
            track.artistId = artist.id
            try track.insert(db)
        }
        let trackID = try #require(track.id)
        let deleted = try appDB.writer.write { try artist.delete($0) }
        #expect(deleted)
        let after = try appDB.writer.read { try TrackRecord.fetchOne($0, key: trackID) }
        #expect(after != nil)
        #expect(after?.artistId == nil)
    }
}
