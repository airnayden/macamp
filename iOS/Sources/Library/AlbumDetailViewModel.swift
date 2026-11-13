// AlbumDetailViewModel — the keyset-paginated track window for ONE album (Task 33).
//
// Drives ``AlbumDetailView``, paging ``TrackRepositoryProviding/tracksByAlbum``
// (disc/track keyset) so a long compilation never loads at once. Reads run OFF the
// main actor (`Task.detached`) so the main thread never blocks on a GRDB reader —
// the same QoS-safe pattern as ``GenreBrowserViewModel``. One instance per album.
import Foundation
import Observation
import Persistence

@MainActor
@Observable
final class AlbumDetailViewModel {
    private(set) var tracks: [TrackRecord] = []
    private(set) var isLoading = false
    private(set) var hasMore = true

    @ObservationIgnored private let repository: any TrackRepositoryProviding
    @ObservationIgnored private let albumId: Int64
    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private var cursor: PageCursor<Int64>?

    init(repository: any TrackRepositoryProviding, albumId: Int64, pageSize: Int = 100) {
        self.repository = repository
        self.albumId = albumId
        self.pageSize = max(1, pageSize)
    }

    func loadInitial() async throws {
        cursor = nil
        tracks = []
        hasMore = true
        try await loadMore()
    }

    func loadMore() async throws {
        guard hasMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let page = try await fetchPage(after: cursor)
        tracks.append(contentsOf: page.items)
        cursor = page.nextCursor
        hasMore = page.nextCursor != nil
    }

    private func fetchPage(after cursor: PageCursor<Int64>?) async throws -> Page<TrackRecord, Int64> {
        let repository = repository
        let albumId = albumId
        let pageSize = pageSize
        return try await Task.detached {
            try repository.tracksByAlbum(albumId: albumId, after: cursor, limit: pageSize)
        }.value
    }
}
