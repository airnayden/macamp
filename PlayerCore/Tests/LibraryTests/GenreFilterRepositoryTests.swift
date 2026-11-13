import Foundation
import GRDB
import Persistence
import Testing

@Suite("GenreFilterRepositoryTests")
struct GenreFilterRepositoryTests {
    @Test("distinctGenres returns sorted, distinct real genres and flags untagged tracks")
    func distinctGenresReportsVocabularyAndUntagged() async throws {
        let appDB = try AppDatabase.makeEmpty()
        try LibraryFixtures.seedGenreLibrary(appDB)
        let repo = TrackRepository(appDB)

        let facets = try await repo.distinctGenres()

        #expect(facets.genres == ["Jazz", "Pop", "Rock"])
        #expect(facets.includesUntagged)
    }

    @Test("distinctGenres reports no untagged bucket when every track has a genre")
    func distinctGenresReportsNoUntaggedWhenFullyTagged() async throws {
        let appDB = try AppDatabase.makeEmpty()
        try LibraryFixtures.seedGenreLibrary(appDB, untagged: 0)
        let repo = TrackRepository(appDB)

        let facets = try await repo.distinctGenres()

        #expect(facets.genres == ["Jazz", "Pop", "Rock"])
        #expect(!facets.includesUntagged)
    }

    @Test("tracksByGenre returns only rows of the selected genre")
    func tracksByGenreReturnsOnlySelectedGenre() throws {
        let appDB = try AppDatabase.makeEmpty()
        try LibraryFixtures.seedGenreLibrary(appDB)
        let repo = TrackRepository(appDB)

        let page = try repo.tracksByGenre(genre: "Jazz", after: nil, limit: 100)

        #expect(page.items.count == 3)
        #expect(page.items.allSatisfy { $0.genre == "Jazz" })
    }

    @Test("tracksByGenre with nil returns every track (the All Genres case)")
    func tracksByGenreNilReturnsAll() throws {
        let appDB = try AppDatabase.makeEmpty()
        try LibraryFixtures.seedGenreLibrary(appDB)
        let repo = TrackRepository(appDB)

        let page = try repo.tracksByGenre(genre: nil, after: nil, limit: 100)

        #expect(page.items.count == 9)
    }

    @Test("tracksByGenre with the empty sentinel returns the (no genre) bucket")
    func tracksByGenreEmptyReturnsUntaggedBucket() throws {
        let appDB = try AppDatabase.makeEmpty()
        try LibraryFixtures.seedGenreLibrary(appDB)
        let repo = TrackRepository(appDB)
        _ = try repo.insert(TrackRecord(filePath: "/music/genre/empty.flac", title: "Z", sortTitle: "Z", genre: ""))

        let page = try repo.tracksByGenre(genre: "", after: nil, limit: 100)

        #expect(page.items.count == 3)
        #expect(page.items.allSatisfy { ($0.genre ?? "").isEmpty })
    }

    @Test("tracksByGenre matches case-insensitively (COLLATE NOCASE)")
    func tracksByGenreIsCaseInsensitive() throws {
        let appDB = try AppDatabase.makeEmpty()
        try LibraryFixtures.seedGenreLibrary(appDB)
        let repo = TrackRepository(appDB)

        let page = try repo.tracksByGenre(genre: "jAzZ", after: nil, limit: 100)

        #expect(page.items.count == 3)
        #expect(page.items.allSatisfy { $0.genre == "Jazz" })
    }

    @Test("tracksByGenre keyset pages cover every matching row exactly once")
    func tracksByGenreKeysetPaginatesWithoutOverlap() throws {
        let appDB = try AppDatabase.makeEmpty()
        try LibraryFixtures.seedGenreLibrary(appDB, jazz: 25, rock: 5, pop: 5, untagged: 5)
        let repo = TrackRepository(appDB)

        var collected: [Int64] = []
        var cursor: PageCursor<Int64>?
        var pageCount = 0
        repeat {
            let page = try repo.tracksByGenre(genre: "Jazz", after: cursor, limit: 10)
            collected.append(contentsOf: page.items.compactMap(\.id))
            cursor = page.nextCursor
            pageCount += 1
        } while cursor != nil && pageCount < 50

        #expect(collected.count == 25)
        #expect(Set(collected).count == 25)
        #expect(pageCount == 3)
    }
}
