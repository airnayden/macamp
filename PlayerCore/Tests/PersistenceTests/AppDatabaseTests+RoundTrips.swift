import Foundation
import GRDB
import Persistence
import Testing

extension AppDatabaseTests {
    @Test("ArtistRecord save / fetch / update / delete")
    func artistRoundTrip() throws {
        let appDB = try AppDatabase.makeEmpty()
        var artist = ArtistRecord(name: "Pink Floyd", sortName: "Pink Floyd", mbid: "mb-1")
        try appDB.writer.write { try artist.insert($0) }
        let id = try #require(artist.id)

        let fetched = try appDB.writer.read { try ArtistRecord.fetchOne($0, key: id) }
        #expect(fetched == artist)

        artist.sortName = "Floyd, Pink"
        try appDB.writer.write { try artist.update($0) }
        let updated = try appDB.writer.read { try ArtistRecord.fetchOne($0, key: id) }
        #expect(updated?.sortName == "Floyd, Pink")

        let deleted = try appDB.writer.write { try artist.delete($0) }
        #expect(deleted)
        let gone = try appDB.writer.read { try ArtistRecord.fetchOne($0, key: id) }
        #expect(gone == nil)
    }

    @Test("AlbumRecord save / fetch / update / delete")
    func albumRoundTrip() throws {
        let appDB = try AppDatabase.makeEmpty()
        var artist = ArtistRecord(name: "Pink Floyd", sortName: "Pink Floyd")
        var album = AlbumRecord(title: "The Wall", sortTitle: "Wall, The", year: 1979)
        try appDB.writer.write { db in
            try artist.insert(db)
            album.artistId = artist.id
            try album.insert(db)
        }
        let id = try #require(album.id)

        let fetched = try appDB.writer.read { try AlbumRecord.fetchOne($0, key: id) }
        #expect(fetched == album)

        album.year = 1980
        try appDB.writer.write { try album.update($0) }
        let updated = try appDB.writer.read { try AlbumRecord.fetchOne($0, key: id) }
        #expect(updated?.year == 1980)

        let deleted = try appDB.writer.write { try album.delete($0) }
        #expect(deleted)
        let gone = try appDB.writer.read { try AlbumRecord.fetchOne($0, key: id) }
        #expect(gone == nil)
    }

    @Test("TrackRecord save / fetch / update / delete with defaults")
    func trackRoundTrip() throws {
        let appDB = try AppDatabase.makeEmpty()
        var track = TrackRecord(
            filePath: "/Music/cn.flac",
            title: "Comfortably Numb",
            artistName: "Pink Floyd",
            albumTitle: "The Wall",
            duration: 382.3,
            bitrate: 1_024_000,
            sampleRate: 44100,
            bitDepth: 16,
            fileSize: 48_234_112
        )
        try appDB.writer.write { try track.insert($0) }
        let id = try #require(track.id)

        let fetched = try appDB.writer.read { try TrackRecord.fetchOne($0, key: id) }
        #expect(fetched == track)
        #expect(fetched?.availability == .present)
        #expect(fetched?.playCount == 0)

        track.availability = .externalOffline
        track.playCount = 3
        try appDB.writer.write { try track.update($0) }
        let updated = try appDB.writer.read { try TrackRecord.fetchOne($0, key: id) }
        #expect(updated?.availability == .externalOffline)
        #expect(updated?.playCount == 3)

        let deleted = try appDB.writer.write { try track.delete($0) }
        #expect(deleted)
        let gone = try appDB.writer.read { try TrackRecord.fetchOne($0, key: id) }
        #expect(gone == nil)
    }

    @Test("PlaylistRecord save / fetch / update / delete")
    func playlistRoundTrip() throws {
        let appDB = try AppDatabase.makeEmpty()
        var playlist = PlaylistRecord(name: "Roadtrip")
        try appDB.writer.write { try playlist.insert($0) }
        let id = try #require(playlist.id)

        let fetched = try appDB.writer.read { try PlaylistRecord.fetchOne($0, key: id) }
        #expect(fetched == playlist)
        #expect(fetched?.isSmartPlaylist == false)

        playlist.name = "Roadtrip 2026"
        try appDB.writer.write { try playlist.update($0) }
        let updated = try appDB.writer.read { try PlaylistRecord.fetchOne($0, key: id) }
        #expect(updated?.name == "Roadtrip 2026")

        let deleted = try appDB.writer.write { try playlist.delete($0) }
        #expect(deleted)
        let gone = try appDB.writer.read { try PlaylistRecord.fetchOne($0, key: id) }
        #expect(gone == nil)
    }

    @Test("PlaylistTrackRecord save / fetch / update / delete")
    func playlistTrackRoundTrip() throws {
        let appDB = try AppDatabase.makeEmpty()
        var playlist = PlaylistRecord(name: "P")
        var track = TrackRecord(filePath: "/Music/x.flac")
        var entry: PlaylistTrackRecord!
        try appDB.writer.write { db in
            try playlist.insert(db)
            try track.insert(db)
            let playlistID = try #require(playlist.id)
            let trackID = try #require(track.id)
            entry = PlaylistTrackRecord(playlistId: playlistID, trackId: trackID, position: 0)
            try entry.insert(db)
        }
        let id = try #require(entry.id)

        let fetched = try appDB.writer.read { try PlaylistTrackRecord.fetchOne($0, key: id) }
        #expect(fetched == entry)

        entry.position = 5
        try appDB.writer.write { try entry.update($0) }
        let updated = try appDB.writer.read { try PlaylistTrackRecord.fetchOne($0, key: id) }
        #expect(updated?.position == 5)

        let deleted = try appDB.writer.write { try entry.delete($0) }
        #expect(deleted)
        let gone = try appDB.writer.read { try PlaylistTrackRecord.fetchOne($0, key: id) }
        #expect(gone == nil)
    }

    @Test("SmartPlaylistRecord save / fetch / update / delete")
    func smartPlaylistRoundTrip() throws {
        let appDB = try AppDatabase.makeEmpty()
        var playlist = PlaylistRecord(name: "Recently Added", isSmartPlaylist: true)
        var smart: SmartPlaylistRecord!
        try appDB.writer.write { db in
            try playlist.insert(db)
            let playlistID = try #require(playlist.id)
            smart = SmartPlaylistRecord(playlistId: playlistID, rulesJson: #"{"limit":50}"#)
            try smart.insert(db)
        }
        let id = try #require(smart.id)

        let fetched = try appDB.writer.read { try SmartPlaylistRecord.fetchOne($0, key: id) }
        #expect(fetched == smart)

        smart.rulesJson = #"{"limit":100}"#
        try appDB.writer.write { try smart.update($0) }
        let updated = try appDB.writer.read { try SmartPlaylistRecord.fetchOne($0, key: id) }
        #expect(updated?.rulesJson == #"{"limit":100}"#)

        let deleted = try appDB.writer.write { try smart.delete($0) }
        #expect(deleted)
        let gone = try appDB.writer.read { try SmartPlaylistRecord.fetchOne($0, key: id) }
        #expect(gone == nil)
    }

    @Test("ArtworkRefRecord save / fetch / update / delete")
    func artworkRefRoundTrip() throws {
        let appDB = try AppDatabase.makeEmpty()
        var artwork = ArtworkRefRecord(contentHash: "sha256-abc", diskPath: "/cache/abc.jpg", width: 600, height: 600)
        try appDB.writer.write { try artwork.insert($0) }
        let id = try #require(artwork.id)

        let fetched = try appDB.writer.read { try ArtworkRefRecord.fetchOne($0, key: id) }
        #expect(fetched == artwork)

        artwork.width = 1200
        artwork.height = 1200
        try appDB.writer.write { try artwork.update($0) }
        let updated = try appDB.writer.read { try ArtworkRefRecord.fetchOne($0, key: id) }
        #expect(updated?.width == 1200)

        let deleted = try appDB.writer.write { try artwork.delete($0) }
        #expect(deleted)
        let gone = try appDB.writer.read { try ArtworkRefRecord.fetchOne($0, key: id) }
        #expect(gone == nil)
    }

    @Test("BookmarkRecord save / fetch / update / delete")
    func bookmarkRoundTrip() throws {
        let appDB = try AppDatabase.makeEmpty()
        var bookmark = BookmarkRecord(
            scope: "libraryRoot",
            bookmarkData: Data([0x01, 0x02, 0x03, 0x04]),
            resolvedPath: "/Volumes/Music"
        )
        try appDB.writer.write { try bookmark.insert($0) }
        let id = try #require(bookmark.id)

        let fetched = try appDB.writer.read { try BookmarkRecord.fetchOne($0, key: id) }
        #expect(fetched == bookmark)
        #expect(fetched?.bookmarkData == Data([0x01, 0x02, 0x03, 0x04]))

        bookmark.resolvedPath = "/Volumes/Music2"
        try appDB.writer.write { try bookmark.update($0) }
        let updated = try appDB.writer.read { try BookmarkRecord.fetchOne($0, key: id) }
        #expect(updated?.resolvedPath == "/Volumes/Music2")

        let deleted = try appDB.writer.write { try bookmark.delete($0) }
        #expect(deleted)
        let gone = try appDB.writer.read { try BookmarkRecord.fetchOne($0, key: id) }
        #expect(gone == nil)
    }
}
