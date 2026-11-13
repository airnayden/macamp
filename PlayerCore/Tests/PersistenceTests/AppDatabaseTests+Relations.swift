import Foundation
import GRDB
import Persistence
import Testing

private struct AlbumWithTracks: Decodable, FetchableRecord {
    var album: AlbumRecord
    var tracks: [TrackRecord]
}

extension AppDatabaseTests {
    @Test("belongsTo / hasMany resolve across artist, album, track")
    func belongsToHasMany() throws {
        let appDB = try AppDatabase.makeEmpty()
        var artist = ArtistRecord(name: "Floyd", sortName: "Floyd")
        var album = AlbumRecord(title: "Wall", sortTitle: "Wall")
        var track = TrackRecord(filePath: "/a.flac")
        try appDB.writer.write { db in
            try artist.insert(db)
            album.artistId = artist.id
            try album.insert(db)
            track.artistId = artist.id
            track.albumId = album.id
            try track.insert(db)
        }

        try appDB.writer.read { db in
            try #expect(track.album.fetchOne(db)?.id == album.id)
            try #expect(track.artist.fetchOne(db)?.id == artist.id)
            try #expect(album.artist.fetchOne(db)?.id == artist.id)
            let albumTracks = try album.tracks.fetchAll(db)
            #expect(albumTracks.map(\.id) == [track.id])
            let artistAlbums = try artist.albums.fetchAll(db)
            #expect(artistAlbums.map(\.id) == [album.id])
        }
    }

    @Test("hasManyThrough: playlist.tracks via join table")
    func hasManyThrough() throws {
        let appDB = try AppDatabase.makeEmpty()
        var playlist = PlaylistRecord(name: "Mix")
        var trackOne = TrackRecord(filePath: "/1.flac")
        var trackTwo = TrackRecord(filePath: "/2.flac")
        try appDB.writer.write { db in
            try playlist.insert(db)
            try trackOne.insert(db)
            try trackTwo.insert(db)
            let playlistID = try #require(playlist.id)
            let trackOneID = try #require(trackOne.id)
            let trackTwoID = try #require(trackTwo.id)
            var entryOne = PlaylistTrackRecord(playlistId: playlistID, trackId: trackOneID, position: 0)
            var entryTwo = PlaylistTrackRecord(playlistId: playlistID, trackId: trackTwoID, position: 1)
            try entryOne.insert(db)
            try entryTwo.insert(db)
        }

        try appDB.writer.read { db in
            let tracks = try playlist.tracks.fetchAll(db)
            #expect(Set(tracks.map(\.id)) == Set([trackOne.id, trackTwo.id]))
            let smart = try playlist.smartPlaylist.fetchOne(db)
            #expect(smart == nil)
        }
    }

    @Test("including(all:) is a constant 2 queries regardless of album count")
    func noNPlusOne() throws {
        let appDB = try AppDatabase.makeEmpty()
        try appDB.writer.write { db in
            for albumIndex in 0 ..< 10 {
                var album = AlbumRecord(title: "Album \(albumIndex)", sortTitle: "Album \(albumIndex)")
                try album.insert(db)
                let albumID = album.id
                for trackIndex in 0 ..< 5 {
                    var track = TrackRecord(filePath: "/music/\(albumIndex)/\(trackIndex).flac", albumId: albumID)
                    try track.insert(db)
                }
            }
        }

        let warm = try appDB.writer.read { db in
            try AlbumRecord.including(all: AlbumRecord.tracks)
                .asRequest(of: AlbumWithTracks.self)
                .fetchAll(db)
        }
        #expect(warm.count == 10)
        #expect(warm.allSatisfy { $0.tracks.count == 5 })

        var statements: [String] = []
        let infos = try appDB.writer.read { db in
            db.trace(options: .statement) { event in
                if case let .statement(statement) = event {
                    statements.append(statement.sql)
                }
            }
            return try AlbumRecord.including(all: AlbumRecord.tracks)
                .asRequest(of: AlbumWithTracks.self)
                .fetchAll(db)
        }

        let selectCount = statements.count(where: { $0.uppercased().hasPrefix("SELECT") })
        #expect(infos.count == 10)
        #expect(
            selectCount == 2,
            "including(all:) must issue 2 SELECTs (base + prefetch), not 1+N. Got \(selectCount): \(statements)"
        )
    }

    @Test("including(all:) query count does not grow with row count")
    func nPlusOneInvariant() throws {
        func selectCount(albumCount: Int) throws -> Int {
            let appDB = try AppDatabase.makeEmpty()
            try appDB.writer.write { db in
                for albumIndex in 0 ..< albumCount {
                    var album = AlbumRecord(title: "A\(albumIndex)", sortTitle: "A\(albumIndex)")
                    try album.insert(db)
                    var track = TrackRecord(filePath: "/inv/\(albumCount)/\(albumIndex).flac", albumId: album.id)
                    try track.insert(db)
                }
            }
            _ = try appDB.writer.read { db in
                try AlbumRecord.including(all: AlbumRecord.tracks)
                    .asRequest(of: AlbumWithTracks.self)
                    .fetchAll(db)
            }
            var statements: [String] = []
            _ = try appDB.writer.read { db in
                db.trace(options: .statement) { event in
                    if case let .statement(statement) = event {
                        statements.append(statement.sql)
                    }
                }
                return try AlbumRecord.including(all: AlbumRecord.tracks)
                    .asRequest(of: AlbumWithTracks.self)
                    .fetchAll(db)
            }
            return statements.count(where: { $0.uppercased().hasPrefix("SELECT") })
        }

        let small = try selectCount(albumCount: 3)
        let large = try selectCount(albumCount: 50)
        #expect(small == large)
        #expect(small == 2)
    }
}
