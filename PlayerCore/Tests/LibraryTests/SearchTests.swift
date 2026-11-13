import Foundation
import GRDB
import Persistence
import Testing

@Suite("SearchTests")
struct SearchTests {
    private func seededRepo() throws -> TrackRepository {
        let appDB = try AppDatabase.makeEmpty()
        try LibraryFixtures.seedSearchCorpus(appDB)
        return TrackRepository(appDB)
    }

    @Test("multi-term prefix query 'boh rha' matches only 'Bohemian Rhapsody'")
    func multiTermPrefixMatch() throws {
        let repo = try seededRepo()
        let results = try repo.searchTracks(query: "boh rha", limit: 50)
        #expect(results.count == 1)
        #expect(results.first?.title == "Bohemian Rhapsody")
    }

    @Test("single prefix token 'boh' matches every track with a boh* token")
    func prefixMatchesAllBohTokens() throws {
        let repo = try seededRepo()
        let results = try repo.searchTracks(query: "boh", limit: 50)
        let titles = Set(results.compactMap(\.title))
        #expect(titles.contains("Bohemian Rhapsody"))
        #expect(titles.contains("Bohemian Like You"))
        #expect(titles.contains("La Bohème"))
    }

    @Test("diacritics fold both ways: unaccented queries match accented titles")
    func accentInsensitiveMatch() throws {
        let repo = try seededRepo()

        let cafe = try repo.searchTracks(query: "cafe", limit: 50)
        #expect(cafe.contains { $0.title == "Café del Mar" })

        let boheme = try repo.searchTracks(query: "boheme", limit: 50)
        #expect(boheme.contains { $0.title == "La Bohème" })

        let accented = try repo.searchTracks(query: "Bohème", limit: 50)
        #expect(accented.contains { $0.title == "La Bohème" })

        let naive = try repo.searchTracks(query: "naive", limit: 50)
        #expect(naive.contains { $0.title == "Naïve" })
    }

    @Test("results are ranked by relevance (more column matches rank higher)")
    func rankedByRelevance() throws {
        let repo = try seededRepo()
        let results = try repo.searchTracks(query: "queen", limit: 50)
        let titles = results.compactMap(\.title)
        let killerIndex = try #require(titles.firstIndex(of: "Killer Queen"))
        let bohemianIndex = try #require(titles.firstIndex(of: "Bohemian Rhapsody"))
        #expect(killerIndex < bohemianIndex)
    }

    @Test("blank query returns no rows")
    func blankQueryReturnsNothing() throws {
        let repo = try seededRepo()
        let results = try repo.searchTracks(query: "   ", limit: 50)
        #expect(results.isEmpty)
    }

    @Test("the synchronized index reflects inserts and deletes")
    func indexStaysInSyncOnDelete() throws {
        let appDB = try AppDatabase.makeEmpty()
        let repo = TrackRepository(appDB)
        let track = try repo.insert(TrackRecord(
            filePath: "/x.flac",
            title: "Stairway to Heaven",
            sortTitle: "Stairway to Heaven",
            artistName: "Led Zeppelin",
            albumTitle: "Led Zeppelin IV"
        ))
        let id = try #require(track.id)

        let beforeDelete = try repo.searchTracks(query: "stairway", limit: 10)
        #expect(beforeDelete.count == 1)

        try #expect(repo.deleteTrack(id: id))
        let afterDelete = try repo.searchTracks(query: "stairway", limit: 10)
        #expect(afterDelete.isEmpty)
    }
}
