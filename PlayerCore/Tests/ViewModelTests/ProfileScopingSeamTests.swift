// ProfileScopingSeamTests — proves the `activeProfileId` scoping seam (Task 5)
// that every profile-scoped shared view model exposes: Guest (`1`) by default,
// settable at construction, and re-assignable by the profile-switch seam
// (Task 11). Todos 6/7/12 make the value actually filter repository reads; this
// todo only proves it is plumbed onto — and retained by — each view model.
import Foundation
import Persistence
import Testing
@testable import ViewModels

@MainActor
struct ProfileScopingSeamTests {
    private func makeDatabase() throws -> AppDatabase {
        try AppDatabase.makeEmpty()
    }

    @Test func scopedViewModelsDefaultToGuestProfile() throws {
        let database = try makeDatabase()
        let trackRepository = TrackRepository(database)

        let library = LibraryViewModel(
            trackRepository: trackRepository,
            albumRepository: AlbumRepository(database),
            artistRepository: ArtistRepository(database),
            databaseReader: database.writer
        )
        let search = SearchViewModel(repository: trackRepository)
        let folder = FolderBrowserViewModel(repository: trackRepository, rootPath: "/music")
        let genre = GenreBrowserViewModel(repository: trackRepository, genre: nil)
        let playlists = PlaylistViewModel(repository: PlaylistRepository(database))

        #expect(library.activeProfileId == 1)
        #expect(search.activeProfileId == 1)
        #expect(folder.activeProfileId == 1)
        #expect(genre.activeProfileId == 1)
        #expect(playlists.activeProfileId == 1)
    }

    @Test func scopedViewModelsRetainConstructionProfileId() throws {
        let database = try makeDatabase()
        let trackRepository = TrackRepository(database)

        let library = LibraryViewModel(
            trackRepository: trackRepository,
            albumRepository: AlbumRepository(database),
            artistRepository: ArtistRepository(database),
            databaseReader: database.writer,
            activeProfileId: 2
        )
        let search = SearchViewModel(repository: trackRepository, activeProfileId: 2)
        let folder = FolderBrowserViewModel(repository: trackRepository, rootPath: "/music", activeProfileId: 2)
        let genre = GenreBrowserViewModel(repository: trackRepository, genre: nil, activeProfileId: 2)
        let playlists = PlaylistViewModel(repository: PlaylistRepository(database), activeProfileId: 2)

        #expect(library.activeProfileId == 2)
        #expect(search.activeProfileId == 2)
        #expect(folder.activeProfileId == 2)
        #expect(genre.activeProfileId == 2)
        #expect(playlists.activeProfileId == 2)
    }

    @Test func activeProfileIdIsReassignableForTheSwitchSeam() throws {
        let database = try makeDatabase()
        let search = SearchViewModel(repository: TrackRepository(database), activeProfileId: 2)
        #expect(search.activeProfileId == 2)

        search.activeProfileId = 3
        #expect(search.activeProfileId == 3)
    }
}
