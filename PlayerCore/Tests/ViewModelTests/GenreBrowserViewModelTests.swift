// GenreBrowserViewModelTests — proves the genre-filter UI seam (Task 14): the
// shared `GenreFilter` option builder and the `GenreBrowserViewModel` track
// window that both shells drive when a specific genre / the untagged bucket is
// selected. Seeds inline (LibraryFixtures lives in the LibraryTests target).
import Foundation
import Persistence
import Testing
@testable import ViewModels

@MainActor
struct GenreBrowserViewModelTests {
    @Test func optionsIncludeAllGenresThenNamedGenresThenUntagged() {
        let facets = LibraryGenreFacets(genres: ["Jazz", "Pop"], includesUntagged: true)
        let options = GenreFilter.options(from: facets)
        #expect(options == [.all, .genre("Jazz"), .genre("Pop"), .untagged])
    }

    @Test func optionsOmitUntaggedBucketWhenLibraryFullyTagged() {
        let facets = LibraryGenreFacets(genres: ["Rock"], includesUntagged: false)
        let options = GenreFilter.options(from: facets)
        #expect(options == [.all, .genre("Rock")])
    }

    @Test func queryArgumentMapsSelectionToRepositoryArgument() {
        #expect(GenreFilter.all.queryArgument == nil)
        #expect(GenreFilter.untagged.queryArgument == "")
        #expect(GenreFilter.genre("Jazz").queryArgument == "Jazz")
    }

    @Test func selectingGenreShowsOnlyThatGenresTracks() async throws {
        let database = try AppDatabase.makeEmpty()
        let repo = TrackRepository(database)
        try seedGenreTracks(repo)

        let model = GenreBrowserViewModel(
            repository: repo,
            genre: GenreFilter.genre("Jazz").queryArgument
        )
        try await model.loadInitial()

        #expect(model.tracks.count == 3)
        #expect(model.tracks.allSatisfy { $0.genre == "Jazz" })
    }

    @Test func selectingUntaggedShowsOnlyGenrelessTracks() async throws {
        let database = try AppDatabase.makeEmpty()
        let repo = TrackRepository(database)
        try seedGenreTracks(repo)

        let model = GenreBrowserViewModel(
            repository: repo,
            genre: GenreFilter.untagged.queryArgument
        )
        try await model.loadInitial()

        #expect(model.tracks.count == 2)
        #expect(model.tracks.allSatisfy { $0.genre == nil })
    }

    @Test func genrePagesGrowTheWindowByKeyset() async throws {
        let database = try AppDatabase.makeEmpty()
        let repo = TrackRepository(database)
        for index in 0 ..< 5 {
            _ = try repo.insert(makeGenreTrack(index: index, genre: "Jazz"))
        }

        let model = GenreBrowserViewModel(repository: repo, genre: "Jazz", pageSize: 2)
        try await model.loadInitial()
        #expect(model.tracks.count == 2)
        #expect(model.hasMore)

        try await model.loadMore()
        try await model.loadMore()
        #expect(model.tracks.count == 5)
        #expect(!model.hasMore)
    }

    @Test func reentrantLoadInitialDuringLoadMoreNeverEmptiesGenreWindow() async throws {
        let database = try AppDatabase.makeEmpty()
        let repo = TrackRepository(database)
        for index in 0 ..< 5 {
            _ = try repo.insert(makeGenreTrack(index: index, genre: "Jazz"))
        }
        let model = GenreBrowserViewModel(repository: repo, genre: "Jazz", pageSize: 2)

        try await model.loadInitial()
        #expect(model.tracks.count == 2)

        async let paging: Void = model.loadMore()
        async let reload: Void = model.loadInitial()
        _ = try await (paging, reload)

        #expect(!model.tracks.isEmpty)
        #expect(model.tracks.count >= 2)
        #expect(model.tracks.allSatisfy { $0.genre == "Jazz" })
    }
}

private func makeGenreTrack(index: Int, genre: String?) -> TrackRecord {
    TrackRecord(
        filePath: "/music/genre/\(index).flac",
        title: String(format: "Track %02d", index),
        sortTitle: String(format: "track %02d", index),
        genre: genre
    )
}

private func seedGenreTracks(_ repo: TrackRepository) throws {
    let specs: [(genre: String?, count: Int)] = [("Jazz", 3), ("Rock", 2), (nil, 2)]
    var index = 0
    for spec in specs {
        for _ in 0 ..< spec.count {
            _ = try repo.insert(makeGenreTrack(index: index, genre: spec.genre))
            index += 1
        }
    }
}
