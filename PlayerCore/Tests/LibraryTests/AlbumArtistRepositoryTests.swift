import Foundation
import GRDB
import Persistence
import Testing

@Suite("AlbumArtistRepositoryTests")
struct AlbumArtistRepositoryTests {
    @Test("AlbumRecord CRUD via the repository")
    func albumCrud() throws {
        let appDB = try AppDatabase.makeEmpty()
        let repo = AlbumRepository(appDB)
        let inserted = try repo.insert(AlbumRecord(title: "X", sortTitle: "X", year: 2000))
        let id = try #require(inserted.id)

        let fetchedOpt = try repo.fetchAlbum(id: id)
        var album = try #require(fetchedOpt)
        #expect(album.title == "X")

        album.year = 2001
        try repo.update(album)
        let updated = try repo.fetchAlbum(id: id)
        #expect(updated?.year == 2001)

        try #expect(repo.deleteAlbum(id: id))
        let gone = try repo.fetchAlbum(id: id)
        #expect(gone == nil)
    }

    @Test("ArtistRecord CRUD via the repository")
    func artistCrud() throws {
        let appDB = try AppDatabase.makeEmpty()
        let repo = ArtistRepository(appDB)
        let inserted = try repo.insert(ArtistRecord(name: "Queen", sortName: "Queen"))
        let id = try #require(inserted.id)

        let fetchedOpt = try repo.fetchArtist(id: id)
        var artist = try #require(fetchedOpt)
        #expect(artist.name == "Queen")

        artist.sortName = "Queen, The"
        try repo.update(artist)
        let updated = try repo.fetchArtist(id: id)
        #expect(updated?.sortName == "Queen, The")

        try #expect(repo.deleteArtist(id: id))
        let gone = try repo.fetchArtist(id: id)
        #expect(gone == nil)
    }

    @Test("albumsWithTracksPage issues exactly 2 SELECTs, invariant to album count")
    func albumsWithTracksAvoidsNPlusOne() throws {
        func selectCount(albumCount: Int) throws -> Int {
            let (appDB, trace) = try LibraryFixtures.makeTracedDatabase()
            try LibraryFixtures.seedAlbums(appDB, albumCount: albumCount, tracksPerAlbum: 5)
            let repo = AlbumRepository(appDB)
            trace.reset()
            let page = try repo.albumsWithTracksPage(after: nil, limit: albumCount)
            #expect(page.items.count == albumCount)
            #expect(page.items.allSatisfy { $0.tracks.count == 5 })
            return trace.selectCount
        }

        let small = try selectCount(albumCount: 3)
        let large = try selectCount(albumCount: 50)
        #expect(small == 2)
        #expect(large == 2)
        #expect(small == large)
    }

    @Test("albumsWithTrackCounts issues exactly 1 SELECT, invariant to album count")
    func albumsWithTrackCountsAvoidsNPlusOne() throws {
        func selectCount(albumCount: Int) throws -> Int {
            let (appDB, trace) = try LibraryFixtures.makeTracedDatabase()
            try LibraryFixtures.seedAlbums(appDB, albumCount: albumCount, tracksPerAlbum: 4)
            let repo = AlbumRepository(appDB)
            trace.reset()
            let page = try repo.albumsWithTrackCounts(after: nil, limit: albumCount)
            #expect(page.items.count == albumCount)
            #expect(page.items.allSatisfy { $0.trackCount == 4 })
            return trace.selectCount
        }

        let small = try selectCount(albumCount: 3)
        let large = try selectCount(albumCount: 50)
        #expect(small == 1)
        #expect(large == 1)
    }

    @Test("artistsWithAlbumCounts issues exactly 1 SELECT")
    func artistsWithAlbumCountsAvoidsNPlusOne() throws {
        let (appDB, trace) = try LibraryFixtures.makeTracedDatabase()
        try LibraryFixtures.seedArtists(appDB, artistCount: 20, albumsPerArtist: 3)
        let repo = ArtistRepository(appDB)
        trace.reset()
        let page = try repo.artistsWithAlbumCounts(after: nil, limit: 100)
        #expect(page.items.count == 20)
        #expect(page.items.allSatisfy { $0.albumCount == 3 })
        let count = trace.selectCount
        #expect(count == 1)
    }

    @Test("album keyset pages cover every album once with correct counts")
    func albumKeysetPaginationCoversAll() throws {
        let appDB = try AppDatabase.makeEmpty()
        try LibraryFixtures.seedAlbums(appDB, albumCount: 25, tracksPerAlbum: 2)
        let repo = AlbumRepository(appDB)

        var collectedIDs: [Int64] = []
        var cursor: PageCursor<String>?
        var pageCount = 0
        repeat {
            let page = try repo.albumsWithTrackCounts(after: cursor, limit: 10)
            collectedIDs.append(contentsOf: page.items.compactMap(\.album.id))
            #expect(page.items.allSatisfy { $0.trackCount == 2 })
            cursor = page.nextCursor
            pageCount += 1
        } while cursor != nil && pageCount < 50

        #expect(collectedIDs.count == 25)
        #expect(Set(collectedIDs).count == 25)
        #expect(pageCount == 3)
    }
}
