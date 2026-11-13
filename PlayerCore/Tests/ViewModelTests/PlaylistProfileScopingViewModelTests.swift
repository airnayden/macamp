import Foundation
import Persistence
import Testing
@testable import ViewModels

@MainActor
struct PlaylistProfileScopingViewModelTests {
    private func makeVM(_ database: AppDatabase, profileId: Int64) -> PlaylistViewModel {
        PlaylistViewModel(repository: PlaylistRepository(database), activeProfileId: profileId)
    }

    /// Loads the first page for `profileId` and returns the playlist names.
    private func playlistNames(_ database: AppDatabase, profileId: Int64) async throws -> [String] {
        let model = makeVM(database, profileId: profileId)
        try await model.loadInitialPlaylists()
        return model.playlists.map(\.playlist.name)
    }

    // MARK: - The list VM is scoped to its active profile

    @Test func viewModelListsOnlyActiveProfilePlaylists() async throws {
        let database = try AppDatabase.makeEmpty()
        let other = try ProfileRepository(database).create(ProfileRecord(name: "Other"))
        let otherId = try #require(other.id)

        try await makeVM(database, profileId: ProfileRecord.guestID).createPlaylist(named: "Guest List")
        try await makeVM(database, profileId: otherId).createPlaylist(named: "Other List")

        #expect(try await playlistNames(database, profileId: ProfileRecord.guestID) == ["Guest List"])
        #expect(try await playlistNames(database, profileId: otherId) == ["Other List"])
    }

    // MARK: - Import lands on the active profile

    @Test func jspfImportLandsOnActiveProfile() async throws {
        let database = try AppDatabase.makeEmpty()
        let profileRepo = ProfileRepository(database)
        let aliceId = try #require(try profileRepo.create(ProfileRecord(name: "Alice")).id)
        let bobId = try #require(try profileRepo.create(ProfileRecord(name: "Bob")).id)

        let jspf = try await seededJSPF(database, ownerId: aliceId)
        let importer = PlaylistImportExportViewModel(
            playlistIO: PlaylistFileIO(database),
            repository: PlaylistRepository(database)
        )
        let outcome = try await importer.importContents(
            jspf,
            format: .json,
            basePath: "/",
            named: "Bob Import",
            profileId: bobId
        )
        #expect(outcome.resolvedCount == 2)
        #expect(outcome.unresolved.isEmpty)

        let imported = try #require(try PlaylistRepository(database).fetchPlaylist(id: outcome.playlistId))
        #expect(imported.profileId == bobId)

        // The imported playlist belongs to Bob alone — not Guest, not Alice.
        #expect(try await playlistNames(database, profileId: ProfileRecord.guestID).isEmpty)
        #expect(try await playlistNames(database, profileId: aliceId) == ["Source"])
        #expect(try await playlistNames(database, profileId: bobId) == ["Bob Import"])
    }

    // MARK: - Deleting a profile cascades its playlists (driven from the VM)

    @Test func deleteProfileCascadesPlaylistsViewModelDriven() async throws {
        let database = try AppDatabase.makeEmpty()
        let profileRepo = ProfileRepository(database)
        let victimId = try #require(try profileRepo.create(ProfileRecord(name: "Victim")).id)

        try await makeVM(database, profileId: ProfileRecord.guestID).createPlaylist(named: "Guest Keeps")
        let victimVM = makeVM(database, profileId: victimId)
        try await victimVM.createPlaylist(named: "Victim A")
        try await victimVM.createPlaylist(named: "Victim B")

        #expect(try await playlistNames(database, profileId: victimId).count == 2)
        #expect(try await playlistNames(database, profileId: ProfileRecord.guestID) == ["Guest Keeps"])

        try profileRepo.delete(id: victimId)

        #expect(try await playlistNames(database, profileId: victimId).isEmpty)
        #expect(try await playlistNames(database, profileId: ProfileRecord.guestID) == ["Guest Keeps"])
    }

    // MARK: - Helpers

    /// Builds a 2-track "Source" playlist owned by `ownerId`, then exports it as JSPF.
    private func seededJSPF(_ database: AppDatabase, ownerId: Int64) async throws -> String {
        let trackRepo = TrackRepository(database)
        let playlistRepo = PlaylistRepository(database)
        let source = try await playlistRepo.create(named: "Source", profileId: ownerId)
        let sourceId = try #require(source.id)
        for path in ["/Music/a.flac", "/Music/b.flac"] {
            let track = try trackRepo.insert(TrackRecord(filePath: path))
            let trackId = try #require(track.id)
            try await playlistRepo.addTrack(trackId: trackId, toPlaylist: sourceId)
        }
        let exporter = PlaylistImportExportViewModel(
            playlistIO: PlaylistFileIO(database),
            repository: playlistRepo
        )
        return try await exporter.exportContents(playlistId: sourceId, format: .json, relativePaths: false)
    }
}
