import Persistence
import Testing
@testable import ViewModels

@MainActor
struct SearchViewModelTests {
    private func seededDatabase() throws -> AppDatabase {
        let database = try AppDatabase.makeEmpty()
        let repository = TrackRepository(database)
        let titles = ["Killer Queen", "Bohemian Rhapsody", "Quick Silver", "Quiet Night", "Question"]
        for (index, title) in titles.enumerated() {
            try repository.insert(makeTrackRecord(
                filePath: "/music/\(index).flac",
                title: title,
                artistName: "Queen"
            ))
        }
        return database
    }

    @Test func debouncedSearchReturnsFTSResults() async throws {
        let database = try seededDatabase()
        let model = SearchViewModel(
            repository: TrackRepository(database),
            debounce: .milliseconds(10),
            pageSize: 50
        )
        model.search("que")
        await pollUntil { !model.results.isEmpty }
        #expect(!model.results.isEmpty)
        #expect(model.results.allSatisfy { ($0.title ?? "").isEmpty == false })
        #expect(!model.isSearching)
    }

    @Test func rapidQueriesCoalesceToOneSearch() async throws {
        let database = try seededDatabase()
        let spy = CountingTrackRepository(TrackRepository(database))
        let model = SearchViewModel(repository: spy, debounce: .milliseconds(20), pageSize: 50)
        model.search("q")
        model.search("qu")
        model.search("que")
        await pollUntil { !model.results.isEmpty }
        #expect(spy.searchCount == 1)
    }

    @Test func loadMoreGrowsTheWindow() async throws {
        let database = try seededDatabase()
        let spy = CountingTrackRepository(TrackRepository(database))
        let model = SearchViewModel(repository: spy, debounce: .zero, pageSize: 2)
        model.search("qu")
        await pollUntil { !model.results.isEmpty }
        let firstCount = model.results.count
        #expect(firstCount == 2)

        model.loadMore()
        await pollUntil { spy.lastLimit == 4 }
        #expect(spy.lastLimit == 4)
        await pollUntil { model.results.count > firstCount }
        #expect(model.results.count > firstCount)
    }

    @Test func emptyQueryClearsResults() async throws {
        let database = try seededDatabase()
        let model = SearchViewModel(repository: TrackRepository(database), debounce: .zero)
        model.search("que")
        await pollUntil { !model.results.isEmpty }
        model.search("   ")
        #expect(model.results.isEmpty)
        #expect(!model.isSearching)
    }
}
