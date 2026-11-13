// ArtistDetailViewModel — the keyset-paginated album + track windows for ONE
// artist (Task 33).
//
// Drives ``ArtistDetailView``: albums page through
// ``AlbumRepositoryProviding/albumsByArtist`` and tracks through
// ``TrackRepositoryProviding/tracksByArtist`` (both keyset by sort key) so a
// prolific artist never loads at once. Reads run OFF the main actor
// (`Task.detached`) so the main thread never blocks on a GRDB reader, mirroring
// ``GenreBrowserViewModel``. One instance per artist.
import Foundation
import Observation
import Persistence

@MainActor
@Observable
final class ArtistDetailViewModel {
    private(set) var albums: [AlbumRecord] = []
    private(set) var tracks: [TrackRecord] = []
    private(set) var isLoadingAlbums = false
    private(set) var isLoadingTracks = false
    private(set) var hasMoreAlbums = true
    private(set) var hasMoreTracks = true

    @ObservationIgnored private let trackRepository: any TrackRepositoryProviding
    @ObservationIgnored private let albumRepository: any AlbumRepositoryProviding
    @ObservationIgnored private let artistId: Int64
    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private var albumCursor: PageCursor<String>?
    @ObservationIgnored private var trackCursor: PageCursor<String>?

    init(
        trackRepository: any TrackRepositoryProviding,
        albumRepository: any AlbumRepositoryProviding,
        artistId: Int64,
        pageSize: Int = 100
    ) {
        self.trackRepository = trackRepository
        self.albumRepository = albumRepository
        self.artistId = artistId
        self.pageSize = max(1, pageSize)
    }

    func loadInitialAlbums() async throws {
        albumCursor = nil
        albums = []
        hasMoreAlbums = true
        try await loadMoreAlbums()
    }

    func loadMoreAlbums() async throws {
        guard hasMoreAlbums, !isLoadingAlbums else { return }
        isLoadingAlbums = true
        defer { isLoadingAlbums = false }
        let page = try await fetchAlbums(after: albumCursor)
        albums.append(contentsOf: page.items)
        albumCursor = page.nextCursor
        hasMoreAlbums = page.nextCursor != nil
    }

    func loadInitialTracks() async throws {
        trackCursor = nil
        tracks = []
        hasMoreTracks = true
        try await loadMoreTracks()
    }

    func loadMoreTracks() async throws {
        guard hasMoreTracks, !isLoadingTracks else { return }
        isLoadingTracks = true
        defer { isLoadingTracks = false }
        let page = try await fetchTracks(after: trackCursor)
        tracks.append(contentsOf: page.items)
        trackCursor = page.nextCursor
        hasMoreTracks = page.nextCursor != nil
    }

    private func fetchAlbums(after cursor: PageCursor<String>?) async throws -> Page<AlbumRecord, String> {
        let albumRepository = albumRepository
        let artistId = artistId
        let pageSize = pageSize
        return try await Task.detached {
            try albumRepository.albumsByArtist(artistId: artistId, after: cursor, limit: pageSize)
        }.value
    }

    private func fetchTracks(after cursor: PageCursor<String>?) async throws -> Page<TrackRecord, String> {
        let trackRepository = trackRepository
        let artistId = artistId
        let pageSize = pageSize
        return try await Task.detached {
            try trackRepository.tracksByArtist(artistId: artistId, after: cursor, limit: pageSize)
        }.value
    }
}
