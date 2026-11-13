import Foundation
import Persistence
import Testing
@testable import ViewModels

/// Task 14 acceptance (b): the karaoke ready-list view model pages its window
/// without duplicates and re-scopes to the active profile on a switch. Uses a
/// fake ``KaraokeReadyPaging`` (no GRDB) that emulates the `(sortTitle, id)`
/// keyset seek so the VM's own cursor/dedup and profile pass-through are the only
/// things under test.
@MainActor
struct KaraokeReadyListViewModelTests {
    @Test func pagesReadyTracksWithoutDuplicates() async throws {
        let profile: Int64 = 1
        let rows = (1 ... 5).map { scoped(id: Int64($0), sortTitle: "t\($0)") }
        let fake = FakeReadyPaging(rowsByProfile: [profile: rows])
        let model = KaraokeReadyListViewModel(repository: fake, pageSize: 2, activeProfileId: profile)

        try await model.loadInitial(paths: rows.map(\.track.filePath))
        #expect(model.tracks.count == 2)
        #expect(model.hasMore)

        var iterations = 0
        while model.hasMore, iterations < 10 {
            try await model.loadMore()
            iterations += 1
        }

        let ids = model.tracks.compactMap(\.track.id)
        #expect(ids == [1, 2, 3, 4, 5])
        #expect(Set(ids).count == ids.count)
        #expect(!model.hasMore)
    }

    @Test func reScopesToNewProfileOnSwitch() async throws {
        let guestRows = [scoped(id: 1, sortTitle: "a")]
        let otherRows = [scoped(id: 2, sortTitle: "b"), scoped(id: 3, sortTitle: "c")]
        let fake = FakeReadyPaging(rowsByProfile: [1: guestRows, 42: otherRows])
        let model = KaraokeReadyListViewModel(repository: fake, pageSize: 10, activeProfileId: 1)

        try await model.loadInitial(paths: ["/m/1.flac"])
        #expect(model.tracks.compactMap(\.track.id) == [1])

        model.activeProfileId = 42
        try await model.loadInitial(paths: ["/m/2.flac", "/m/3.flac"])

        #expect(model.tracks.compactMap(\.track.id) == [2, 3])
        #expect(fake.calls.last?.profileId == 42)
    }

    @Test func filtersByTitleAndArtistCaseInsensitively() async throws {
        let rows = [
            scoped(id: 1, sortTitle: "t1", title: "Hello", artist: "Adele"),
            scoped(id: 2, sortTitle: "t2", title: "Yesterday", artist: "The Beatles"),
            scoped(id: 3, sortTitle: "t3", title: "Bohemian Rhapsody", artist: "Queen"),
        ]
        let fake = FakeReadyPaging(rowsByProfile: [1: rows])
        let model = KaraokeReadyListViewModel(repository: fake, pageSize: 10, activeProfileId: 1)
        try await model.loadInitial(paths: rows.map(\.track.filePath))

        model.searchQuery = "hello"
        #expect(model.filteredRows.compactMap(\.track.id) == [1])

        model.searchQuery = "BEATLES"
        #expect(model.filteredRows.compactMap(\.track.id) == [2])
    }

    @Test func emptyOrWhitespaceQueryReturnsAllLoadedRows() async throws {
        let rows = (1 ... 3).map { scoped(id: Int64($0), sortTitle: "t\($0)", title: "song \($0)", artist: "a\($0)") }
        let fake = FakeReadyPaging(rowsByProfile: [1: rows])
        let model = KaraokeReadyListViewModel(repository: fake, pageSize: 10, activeProfileId: 1)
        try await model.loadInitial(paths: rows.map(\.track.filePath))
        #expect(model.filteredRows.compactMap(\.track.id) == [1, 2, 3])

        model.searchQuery = "   "
        #expect(model.filteredRows.compactMap(\.track.id) == model.tracks.compactMap(\.track.id))
    }

    @Test func loadMoreKeepsActiveFilterApplied() async throws {
        let rows = [
            scoped(id: 1, sortTitle: "t1", title: "Keep One", artist: "x"),
            scoped(id: 2, sortTitle: "t2", title: "Skip Two", artist: "x"),
            scoped(id: 3, sortTitle: "t3", title: "Keep Three", artist: "x"),
            scoped(id: 4, sortTitle: "t4", title: "Skip Four", artist: "x"),
            scoped(id: 5, sortTitle: "t5", title: "Keep Five", artist: "x"),
        ]
        let fake = FakeReadyPaging(rowsByProfile: [1: rows])
        let model = KaraokeReadyListViewModel(repository: fake, pageSize: 2, activeProfileId: 1)

        try await model.loadInitial(paths: rows.map(\.track.filePath))
        model.searchQuery = "keep"
        #expect(model.filteredRows.compactMap(\.track.id) == [1])

        try await model.loadMore()
        #expect(model.filteredRows.compactMap(\.track.id) == [1, 3])

        try await model.loadMore()
        #expect(model.filteredRows.compactMap(\.track.id) == [1, 3, 5])
        #expect(model.tracks.count == 5)
    }

    @Test func matchesDiacriticInsensitively() async throws {
        let rows = [
            scoped(id: 1, sortTitle: "t1", title: "Halo", artist: "Beyoncé"),
            scoped(id: 2, sortTitle: "t2", title: "Yesterday", artist: "The Beatles"),
            scoped(id: 3, sortTitle: "t3", title: "Café del Mar", artist: "Energy 52"),
        ]
        let fake = FakeReadyPaging(rowsByProfile: [1: rows])
        let model = KaraokeReadyListViewModel(repository: fake, pageSize: 10, activeProfileId: 1)
        try await model.loadInitial(paths: rows.map(\.track.filePath))

        model.searchQuery = "beyonce"
        #expect(model.filteredRows.compactMap(\.track.id) == [1])

        model.searchQuery = "cafe"
        #expect(model.filteredRows.compactMap(\.track.id) == [3])
    }
}

private func scoped(id: Int64, sortTitle: String) -> ProfileScopedTrack {
    ProfileScopedTrack(
        track: TrackRecord(id: id, filePath: "/m/\(id).flac", title: sortTitle, sortTitle: sortTitle)
    )
}

private func scoped(id: Int64, sortTitle: String, title: String, artist: String?) -> ProfileScopedTrack {
    ProfileScopedTrack(
        track: TrackRecord(
            id: id,
            filePath: "/m/\(id).flac",
            title: title,
            sortTitle: sortTitle,
            artistName: artist
        )
    )
}

/// Records each call's profile/cursor and returns the `(sortTitle, id)`-ordered
/// rows for that profile strictly after the cursor, capped at `limit` — a keyset
/// page identical in shape to `TrackRepository.tracksByPaths`.
private final class FakeReadyPaging: KaraokeReadyPaging, @unchecked Sendable {
    struct Call {
        let profileId: Int64
        let cursorKey: String?
        let cursorId: Int64?
    }

    private let rowsByProfile: [Int64: [ProfileScopedTrack]]
    private let lock = NSLock()
    private var recorded: [Call] = []

    init(rowsByProfile: [Int64: [ProfileScopedTrack]]) {
        self.rowsByProfile = rowsByProfile
    }

    var calls: [Call] {
        lock.withLock { recorded }
    }

    func readyTracks(
        profileId: Int64,
        paths _: [String],
        after cursor: PageCursor<String>?,
        limit: Int
    ) throws -> [ProfileScopedTrack] {
        lock.withLock {
            recorded.append(Call(profileId: profileId, cursorKey: cursor?.key, cursorId: cursor?.id))
        }
        let ordered = (rowsByProfile[profileId] ?? []).sorted(by: Self.keysetBefore)
        let start: Int = cursor.map { seek in
            ordered.firstIndex { Self.isAfter($0, key: seek.key, id: seek.id) } ?? ordered.count
        } ?? 0
        return Array(ordered[start...].prefix(limit))
    }

    private static func keysetBefore(_ lhs: ProfileScopedTrack, _ rhs: ProfileScopedTrack) -> Bool {
        let leftKey = lhs.track.sortTitle ?? ""
        let rightKey = rhs.track.sortTitle ?? ""
        if leftKey != rightKey { return leftKey < rightKey }
        return (lhs.track.id ?? 0) < (rhs.track.id ?? 0)
    }

    private static func isAfter(_ row: ProfileScopedTrack, key: String, id: Int64) -> Bool {
        let rowKey = row.track.sortTitle ?? ""
        if rowKey != key { return rowKey > key }
        return (row.track.id ?? 0) > id
    }
}
