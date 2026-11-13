// LibraryGridModels — keyset-paginated, off-main backing models for the macOS
// Albums and Artists grids and the album/artist detail screens.
//
// Each model is `@MainActor @Observable` (its published state is read on the main
// actor by SwiftUI) but every database read runs on a detached task so the GRDB
// reader pool is never blocked from the main thread (the Task 3 QoS invariant).
// The album/artist count queries are synchronous-only on the repositories, so
// `Task.detached` is the off-main hop; results are `Sendable` records.
import Foundation
import GRDB
import Observation
import Persistence

/// One page-at-a-time stream of albums with their track counts, ascending by title.
@MainActor
@Observable
final class AlbumsBrowserModel {
    private(set) var albums: [AlbumWithTrackCount] = []
    private(set) var isLoading = false

    private var cursor: PageCursor<String>?
    private var hasMore = true
    private let repository: AlbumRepository
    private let pageSize: Int
    private let profileId: Int64

    init(repository: AlbumRepository, profileId: Int64 = ProfileRecord.guestID, pageSize: Int = 80) {
        self.repository = repository
        self.profileId = profileId
        self.pageSize = pageSize
    }

    func loadInitial() async {
        isLoading = true
        let repo = repository
        let limit = pageSize
        let profileId = profileId
        let page = await Task.detached {
            try? repo.albumsWithTrackCounts(profileId: profileId, after: nil, limit: limit)
        }.value
        if let page {
            albums = page.items
            cursor = page.nextCursor
            hasMore = page.hasMore
        } else {
            hasMore = false
        }
        isLoading = false
    }

    func loadMore() async {
        guard hasMore, !isLoading else { return }
        isLoading = true
        let repo = repository
        let after = cursor
        let limit = pageSize
        let profileId = profileId
        let page = await Task.detached {
            try? repo.albumsWithTrackCounts(profileId: profileId, after: after, limit: limit)
        }.value
        if let page {
            albums.append(contentsOf: page.items)
            cursor = page.nextCursor
            hasMore = page.hasMore
        } else {
            hasMore = false
        }
        isLoading = false
    }

    func loadMoreIfLast(_ entry: AlbumWithTrackCount) {
        guard entry.album.id == albums.last?.album.id else { return }
        Task { await loadMore() }
    }
}

/// One page-at-a-time stream of artists with their album counts, ascending by name.
@MainActor
@Observable
final class ArtistsBrowserModel {
    private(set) var artists: [ArtistWithAlbumCount] = []
    private(set) var isLoading = false

    private var cursor: PageCursor<String>?
    private var hasMore = true
    private let repository: ArtistRepository
    private let pageSize: Int
    private let profileId: Int64

    init(repository: ArtistRepository, profileId: Int64 = ProfileRecord.guestID, pageSize: Int = 100) {
        self.repository = repository
        self.profileId = profileId
        self.pageSize = pageSize
    }

    func loadInitial() async {
        isLoading = true
        let repo = repository
        let limit = pageSize
        let profileId = profileId
        let page = await Task.detached {
            try? repo.artistsWithAlbumCounts(profileId: profileId, after: nil, limit: limit)
        }.value
        if let page {
            artists = page.items
            cursor = page.nextCursor
            hasMore = page.hasMore
        } else {
            hasMore = false
        }
        isLoading = false
    }

    func loadMore() async {
        guard hasMore, !isLoading else { return }
        isLoading = true
        let repo = repository
        let after = cursor
        let limit = pageSize
        let profileId = profileId
        let page = await Task.detached {
            try? repo.artistsWithAlbumCounts(profileId: profileId, after: after, limit: limit)
        }.value
        if let page {
            artists.append(contentsOf: page.items)
            cursor = page.nextCursor
            hasMore = page.hasMore
        } else {
            hasMore = false
        }
        isLoading = false
    }

    func loadMoreIfLast(_ entry: ArtistWithAlbumCount) {
        guard entry.artist.id == artists.last?.artist.id else { return }
        Task { await loadMore() }
    }
}

/// The albums credited to one artist, keyset-paginated ascending by title.
@MainActor
@Observable
final class ArtistAlbumsModel {
    private(set) var albums: [AlbumRecord] = []
    private(set) var isLoading = false

    private var cursor: PageCursor<String>?
    private var hasMore = true
    private let repository: AlbumRepository
    private let artistId: Int64
    private let pageSize: Int
    private let profileId: Int64

    init(repository: AlbumRepository, artistId: Int64, profileId: Int64 = ProfileRecord.guestID, pageSize: Int = 80) {
        self.repository = repository
        self.artistId = artistId
        self.profileId = profileId
        self.pageSize = pageSize
    }

    func loadInitial() async {
        isLoading = true
        let repo = repository
        let limit = pageSize
        let artist = artistId
        let profileId = profileId
        let page = await Task.detached {
            try? repo.albumsByArtist(profileId: profileId, artistId: artist, after: nil, limit: limit)
        }.value
        if let page {
            albums = page.items
            cursor = page.nextCursor
            hasMore = page.hasMore
        } else {
            hasMore = false
        }
        isLoading = false
    }

    func loadMore() async {
        guard hasMore, !isLoading else { return }
        isLoading = true
        let repo = repository
        let after = cursor
        let limit = pageSize
        let artist = artistId
        let profileId = profileId
        let page = await Task.detached {
            try? repo.albumsByArtist(profileId: profileId, artistId: artist, after: after, limit: limit)
        }.value
        if let page {
            albums.append(contentsOf: page.items)
            cursor = page.nextCursor
            hasMore = page.hasMore
        } else {
            hasMore = false
        }
        isLoading = false
    }

    func loadMoreIfLast(_ album: AlbumRecord) {
        guard album.id == albums.last?.id else { return }
        Task { await loadMore() }
    }
}

/// The tracks on one album, loaded off-main and ordered by `(trackNumber, title)`.
/// A single album's track set is naturally bounded, so it is fetched in one read.
@MainActor
@Observable
final class AlbumTracksModel {
    private(set) var tracks: [TrackRecord] = []
    private(set) var isLoading = true

    private let writer: any DatabaseWriter
    private let album: AlbumRecord

    init(writer: any DatabaseWriter, album: AlbumRecord) {
        self.writer = writer
        self.album = album
    }

    func load() async {
        isLoading = true
        let writer = writer
        let album = album
        let loaded = await Task.detached {
            (try? writer.read { db in try album.tracks.fetchAll(db) }) ?? []
        }.value
        tracks = loaded.sorted { ($0.trackNumber ?? 0, $0.title ?? "") < ($1.trackNumber ?? 0, $1.title ?? "") }
        isLoading = false
    }
}
