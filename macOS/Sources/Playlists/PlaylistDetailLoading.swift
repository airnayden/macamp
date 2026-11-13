// PlaylistDetailLoading — the windowed track loading, genre-facet options and
// edit-order draining behind ``PlaylistDetailView``.
//
// Split out of the view file purely to keep each source under the SwiftLint
// file-length limit; the members are internal (not private) because the view's
// `body` in the parent file drives them (`.task`, `.onChange`, row pagination).
// The read path stays keyset-windowed; only entering Edit Order drains every
// unloaded page so a reorder can persist the COMPLETE list.
import Persistence
import ViewModels

extension PlaylistDetailView {
    var loadedRowIds: [Int64] {
        environment.playlists.tracks.compactMap(\.id)
    }

    func load() async {
        isEditingOrder = false
        selection = []
        try? await environment.playlists.loadTracks(for: playlist)
        syncRowsFromModel()
        await loadFavourites()
        await loadGenreOptions()
    }

    func loadFavourites() async {
        let profileId = environment.profileService.activeProfile.id ?? ProfileRecord.guestID
        let repo = TrackRepository(environment.database)
        favouriteIds = await (try? Task.detached { try repo.favouriteTrackIDs(profileId: profileId) }.value) ?? []
    }

    func loadGenreOptions() async {
        guard let playlistId = playlist.id else { return }
        let repository = TrackRepository(environment.database)
        let facets = await (try? repository.distinctGenres(playlistId: playlistId))
            ?? LibraryGenreFacets(genres: [], includesUntagged: false)
        genreOptions = GenreFilter.options(from: facets)
        if !genreOptions.contains(selectedGenre) { selectedGenre = .all }
    }

    func syncRowsFromModel() {
        guard !isEditingOrder else { return }
        orderedRows = environment.playlists.tracks
    }

    func paginate(_ row: PlaylistDetailRow) {
        guard !isEditingOrder else { return }
        guard row.id == environment.playlists.tracks.last?.id, let playlistId = playlist.id else { return }
        Task { try? await environment.playlists.loadMoreTracks(in: playlistId) }
    }

    func handleEditOrderChange(_ editing: Bool) async {
        guard let playlistId = playlist.id else { return }
        if editing {
            while environment.playlists.hasMoreTracks {
                try? await environment.playlists.loadMoreTracks(in: playlistId)
            }
            orderedRows = environment.playlists.tracks
        } else {
            try? await environment.playlists.loadInitialTracks(in: playlistId)
            orderedRows = environment.playlists.tracks
        }
    }
}
