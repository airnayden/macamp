import Foundation
import GRDB
import Persistence
import Testing

@Suite("PlaylistRepositoryTests")
struct PlaylistRepositoryTests {
    @Test("PlaylistRecord CRUD via the repository")
    func playlistCrud() throws {
        let appDB = try AppDatabase.makeEmpty()
        let repo = PlaylistRepository(appDB)
        let inserted = try repo.insert(PlaylistRecord(name: "Mix"))
        let id = try #require(inserted.id)

        let fetchedOpt = try repo.fetchPlaylist(id: id)
        var playlist = try #require(fetchedOpt)
        #expect(playlist.name == "Mix")

        playlist.name = "Mix 2"
        try repo.update(playlist)
        let updated = try repo.fetchPlaylist(id: id)
        #expect(updated?.name == "Mix 2")

        try #expect(repo.deletePlaylist(id: id))
        let gone = try repo.fetchPlaylist(id: id)
        #expect(gone == nil)
    }

    @Test("addTrack appends in order; removeTrack deletes the membership")
    func addAndRemoveTracks() throws {
        let appDB = try AppDatabase.makeEmpty()
        let trackRepo = TrackRepository(appDB)
        let playlistRepo = PlaylistRepository(appDB)
        let playlist = try playlistRepo.insert(PlaylistRecord(name: "P"))
        let playlistID = try #require(playlist.id)

        var trackIDs: [Int64] = []
        for index in 0 ..< 5 {
            let track = try trackRepo.insert(TrackRecord(
                filePath: "/p/\(index).flac",
                title: "T\(index)",
                sortTitle: "T\(index)"
            ))
            let trackID = try #require(track.id)
            trackIDs.append(trackID)
            _ = try playlistRepo.addTrack(trackId: trackID, toPlaylist: playlistID)
        }

        let page = try playlistRepo.playlistTracksPage(playlistId: playlistID, after: nil, limit: 100)
        #expect(page.items.map(\.position) == [0, 1, 2, 3, 4])
        #expect(page.items.compactMap(\.track.id) == trackIDs)

        let removed = try playlistRepo.removeTrack(trackId: trackIDs[2], fromPlaylist: playlistID)
        #expect(removed == 1)
        let afterRemoval = try playlistRepo.playlistTracksPage(playlistId: playlistID, after: nil, limit: 100)
        #expect(afterRemoval.items.count == 4)
        #expect(!afterRemoval.items.contains { $0.track.id == trackIDs[2] })
    }

    @Test("reorder atomically rewrites positions to the new order")
    func reorderRewritesPositions() throws {
        let appDB = try AppDatabase.makeEmpty()
        let trackRepo = TrackRepository(appDB)
        let playlistRepo = PlaylistRepository(appDB)
        let playlist = try playlistRepo.insert(PlaylistRecord(name: "P"))
        let playlistID = try #require(playlist.id)

        var trackIDs: [Int64] = []
        for index in 0 ..< 5 {
            let track = try trackRepo.insert(TrackRecord(filePath: "/r/\(index).flac", sortTitle: "T\(index)"))
            let trackID = try #require(track.id)
            trackIDs.append(trackID)
            _ = try playlistRepo.addTrack(trackId: trackID, toPlaylist: playlistID)
        }

        let reversed = Array(trackIDs.reversed())
        try playlistRepo.reorder(playlistId: playlistID, orderedTrackIds: reversed)

        let page = try playlistRepo.playlistTracksPage(playlistId: playlistID, after: nil, limit: 100)
        #expect(page.items.compactMap(\.track.id) == reversed)
        #expect(page.items.map(\.position) == [0, 1, 2, 3, 4])
    }

    @Test("ordered playlist keyset pages cover every membership once, in position order")
    func playlistTracksKeysetPagination() throws {
        let appDB = try AppDatabase.makeEmpty()
        let trackRepo = TrackRepository(appDB)
        let playlistRepo = PlaylistRepository(appDB)
        let playlist = try playlistRepo.insert(PlaylistRecord(name: "Long"))
        let playlistID = try #require(playlist.id)
        for index in 0 ..< 25 {
            let track = try trackRepo.insert(TrackRecord(filePath: "/long/\(index).flac", sortTitle: "T\(index)"))
            let trackID = try #require(track.id)
            _ = try playlistRepo.addTrack(trackId: trackID, toPlaylist: playlistID)
        }

        var positions: [Int] = []
        var cursor: PageCursor<Int>?
        var pageCount = 0
        repeat {
            let page = try playlistRepo.playlistTracksPage(playlistId: playlistID, after: cursor, limit: 10)
            positions.append(contentsOf: page.items.map(\.position))
            cursor = page.nextCursor
            pageCount += 1
        } while cursor != nil && pageCount < 50

        #expect(positions == Array(0 ..< 25))
        #expect(pageCount == 3)
    }

    @Test("playlistsWithTrackCounts issues exactly 1 SELECT with correct counts")
    func playlistsWithTrackCountsAvoidsNPlusOne() throws {
        let (appDB, trace) = try LibraryFixtures.makeTracedDatabase()
        let trackRepo = TrackRepository(appDB)
        let playlistRepo = PlaylistRepository(appDB)

        for (playlistIndex, trackTotal) in [3, 5, 8].enumerated() {
            let playlist = try playlistRepo.create(named: "List \(playlistIndex)", profileId: 1)
            let playlistID = try #require(playlist.id)
            for trackIndex in 0 ..< trackTotal {
                let track = try trackRepo.insert(TrackRecord(filePath: "/c/\(playlistIndex)/\(trackIndex).flac"))
                let trackID = try #require(track.id)
                _ = try playlistRepo.addTrack(trackId: trackID, toPlaylist: playlistID)
            }
        }

        trace.reset()
        let page = try playlistRepo.playlistsWithTrackCounts(after: nil, limit: 100)
        let counts = page.items.map(\.trackCount).sorted()
        #expect(counts == [3, 5, 8])
        let selectCount = trace.selectCount
        #expect(selectCount == 1)
    }
}
