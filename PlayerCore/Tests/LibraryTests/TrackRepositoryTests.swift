import Foundation
import GRDB
import Persistence
import Testing

@Suite("TrackRepositoryTests")
struct TrackRepositoryTests {
    @Test("CRUD round-trip via the repository")
    func crudRoundTrip() throws {
        let appDB = try AppDatabase.makeEmpty()
        let repo = TrackRepository(appDB)

        let inserted = try repo.insert(TrackRecord(filePath: "/a.flac", title: "A", sortTitle: "A"))
        let id = try #require(inserted.id)

        let fetchedOpt = try repo.fetchTrack(id: id)
        var fetched = try #require(fetchedOpt)
        #expect(fetched.title == "A")

        fetched.title = "B"
        try repo.update(fetched)
        let updated = try repo.fetchTrack(id: id)
        #expect(updated?.title == "B")

        let byPath = try repo.fetchTrack(filePath: "/a.flac")
        #expect(byPath?.id == id)

        try #expect(repo.deleteTrack(id: id))
        let gone = try repo.fetchTrack(id: id)
        #expect(gone == nil)
    }

    @Test("insertBatch inserts every track in one transaction")
    func insertBatchInsertsAll() throws {
        let appDB = try AppDatabase.makeEmpty()
        let repo = TrackRepository(appDB)
        let tracks = (0 ..< 100).map { index in
            TrackRecord(
                filePath: "/batch/\(index).flac",
                title: "T\(index)",
                sortTitle: String(format: "T%03d", index)
            )
        }
        let count = try repo.insertBatch(tracks)
        #expect(count == 100)
        let total = try appDB.writer.read { try TrackRecord.fetchCount($0) }
        #expect(total == 100)
    }

    @Test("keyset pagination covers every row exactly once, in ascending order")
    func keysetPaginationCoversAllRowsOnce() throws {
        let appDB = try AppDatabase.makeEmpty()
        try LibraryFixtures.seedTracks(appDB, count: 25)
        let repo = TrackRepository(appDB)

        var collectedIDs: [Int64] = []
        var collectedTitles: [String] = []
        var cursor: PageCursor<String>?
        var pageCount = 0
        repeat {
            let page = try repo.tracksPage(after: cursor, limit: 10)
            collectedIDs.append(contentsOf: page.items.compactMap(\.id))
            collectedTitles.append(contentsOf: page.items.compactMap(\.title))
            cursor = page.nextCursor
            pageCount += 1
        } while cursor != nil && pageCount < 50

        #expect(collectedIDs.count == 25)
        #expect(Set(collectedIDs).count == 25)
        #expect(collectedTitles == collectedTitles.sorted())
        #expect(pageCount == 3)
    }

    @Test("keyset pages stay stable and non-overlapping when rows are inserted")
    func keysetPaginationStableUnderInsertion() throws {
        let appDB = try AppDatabase.makeEmpty()
        try LibraryFixtures.seedTracks(appDB, count: 20)
        let repo = TrackRepository(appDB)

        let page1 = try repo.tracksPage(after: nil, limit: 10)
        #expect(page1.items.count == 10)
        let cursor = try #require(page1.nextCursor)

        _ = try repo.insert(TrackRecord(
            filePath: "/inserted.flac",
            title: "Track 00000-new",
            sortTitle: "Track 00000-new"
        ))

        let page2 = try repo.tracksPage(after: cursor, limit: 10)
        let page1IDs = Set(page1.items.compactMap(\.id))
        let page2IDs = Set(page2.items.compactMap(\.id))
        #expect(page1IDs.isDisjoint(with: page2IDs))
        #expect(!page2.items.contains { $0.filePath == "/inserted.flac" })
    }

    @Test("recentlyAdded observation is bounded and newest-first")
    func recentlyAddedObservationIsBounded() async throws {
        let appDB = try AppDatabase.makeEmpty()
        try LibraryFixtures.seedTracks(appDB, count: 30)
        let repo = TrackRepository(appDB)
        let observation = repo.recentlyAddedObservation(limit: 5)

        for try await tracks in observation.values(in: appDB.writer) {
            #expect(tracks.count == 5)
            #expect(tracks.first?.title == "Track 00029")
            #expect(tracks.last?.title == "Track 00025")
            break
        }
    }
}
