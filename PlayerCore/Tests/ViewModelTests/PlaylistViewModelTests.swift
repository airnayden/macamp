import Foundation
import Persistence
import Testing
@testable import ViewModels

@MainActor
struct PlaylistViewModelTests {
    private func makeModel(
        _ database: AppDatabase,
        pageSize: Int = 100
    ) -> PlaylistViewModel {
        PlaylistViewModel(
            repository: PlaylistRepository(database),
            pageSize: pageSize
        )
    }

    // MARK: - Create / add / reorder / rename / delete

    @Test func createAddReorderRenameDelete() async throws {
        let database = try AppDatabase.makeEmpty()
        let trackRepository = TrackRepository(database)
        let first = try trackRepository.insert(makeTrackRecord(filePath: "/music/1.flac", title: "One"))
        let second = try trackRepository.insert(makeTrackRecord(filePath: "/music/2.flac", title: "Two"))
        let third = try trackRepository.insert(makeTrackRecord(filePath: "/music/3.flac", title: "Three"))
        let firstId = try #require(first.id)
        let secondId = try #require(second.id)
        let thirdId = try #require(third.id)

        let model = makeModel(database)
        let playlist = try await model.createPlaylist(named: "Mix")
        let playlistId = try #require(playlist.id)

        try await model.addTrack(firstId, toPlaylist: playlistId)
        try await model.addTrack(secondId, toPlaylist: playlistId)
        try await model.addTrack(thirdId, toPlaylist: playlistId)

        try await model.loadInitialTracks(in: playlistId)
        #expect(model.tracks.compactMap(\.track.id) == [firstId, secondId, thirdId])

        // Reorder to [3, 1, 2] and assert the persisted order.
        try await model.reorderTracks(in: playlistId, orderedTrackIds: [thirdId, firstId, secondId])
        try await model.loadInitialTracks(in: playlistId)
        #expect(model.tracks.compactMap(\.track.id) == [thirdId, firstId, secondId])
        #expect(model.tracks.map(\.position) == [0, 1, 2])

        // Rename and assert the new name + preserved count.
        try await model.renamePlaylist(playlist, to: "Renamed")
        try await model.loadInitialPlaylists()
        #expect(model.playlists.map(\.playlist.name) == ["Renamed"])
        #expect(model.playlists.first?.trackCount == 3)

        // Delete and assert it is gone.
        try await model.deletePlaylist(id: playlistId)
        try await model.loadInitialPlaylists()
        #expect(model.playlists.isEmpty)
    }

    // MARK: - Load tracks

    @Test func loadTracksUsesMembershipForPlaylist() async throws {
        let database = try AppDatabase.makeEmpty()
        let trackRepository = TrackRepository(database)
        let track = try trackRepository.insert(makeTrackRecord(filePath: "/music/n.flac", title: "N"))
        let trackId = try #require(track.id)

        let model = makeModel(database)
        let playlist = try await model.createPlaylist(named: "Normal")
        let playlistId = try #require(playlist.id)
        try await model.addTrack(trackId, toPlaylist: playlistId)

        try await model.loadTracks(for: playlist)
        #expect(model.tracks.compactMap(\.track.id) == [trackId])
    }

    // MARK: - Keyset pagination

    @Test func playlistsPaginateByKeyset() async throws {
        let database = try AppDatabase.makeEmpty()
        let model = makeModel(database, pageSize: 2)
        for index in 0 ..< 5 {
            _ = try await model.createPlaylist(named: String(format: "List %02d", index))
        }
        try await model.loadInitialPlaylists()
        #expect(model.playlists.count == 2)
        #expect(model.hasMorePlaylists)

        try await model.loadMorePlaylists()
        #expect(model.playlists.count == 4)

        try await model.loadMorePlaylists()
        #expect(model.playlists.count == 5)
        #expect(!model.hasMorePlaylists)
    }

    @Test func playlistTracksPaginateByKeyset() async throws {
        let database = try AppDatabase.makeEmpty()
        let trackRepository = TrackRepository(database)
        let model = makeModel(database, pageSize: 2)
        let playlist = try await model.createPlaylist(named: "Big")
        let playlistId = try #require(playlist.id)
        for index in 0 ..< 5 {
            let track = try trackRepository.insert(
                makeTrackRecord(filePath: "/music/t-\(index).flac", title: "T \(index)")
            )
            let trackId = try #require(track.id)
            try await model.addTrack(trackId, toPlaylist: playlistId)
        }
        try await model.loadInitialTracks(in: playlistId)
        #expect(model.tracks.count == 2)
        #expect(model.hasMoreTracks)

        try await model.loadMoreTracks(in: playlistId)
        #expect(model.tracks.count == 4)

        try await model.loadMoreTracks(in: playlistId)
        #expect(model.tracks.count == 5)
        #expect(!model.hasMoreTracks)
    }
}
