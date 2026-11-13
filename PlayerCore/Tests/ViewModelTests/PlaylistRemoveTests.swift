import Foundation
import Persistence
import Testing
@testable import ViewModels

@MainActor
struct PlaylistRemoveTests {
    private func makeModel(_ database: AppDatabase) -> PlaylistViewModel {
        PlaylistViewModel(repository: PlaylistRepository(database))
    }

    @Test func removeTrackFromPlaylistKeepsLibraryRow() async throws {
        let database = try AppDatabase.makeEmpty()
        let trackRepository = TrackRepository(database)
        let track = try trackRepository.insert(makeTrackRecord(filePath: "/music/keep.flac", title: "Keep Me"))
        let trackId = try #require(track.id)

        let model = makeModel(database)
        let playlist = try await model.createPlaylist(named: "Temp")
        let playlistId = try #require(playlist.id)
        try await model.addTrack(trackId, toPlaylist: playlistId)

        try await model.loadInitialTracks(in: playlistId)
        #expect(model.tracks.compactMap(\.track.id) == [trackId])

        try await model.removeTrack(trackId, fromPlaylist: playlistId)
        try await model.loadInitialTracks(in: playlistId)
        #expect(model.tracks.isEmpty)

        let survivor = try trackRepository.fetchTrack(id: trackId)
        #expect(survivor != nil)
        #expect(survivor?.filePath == "/music/keep.flac")
        #expect(survivor?.availability == .present)

        try await model.loadInitialPlaylists()
        #expect(model.playlists.map(\.playlist.name) == ["Temp"])
        #expect(model.playlists.first?.trackCount == 0)
    }
}
