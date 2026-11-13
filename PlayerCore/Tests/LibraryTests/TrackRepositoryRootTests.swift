import Foundation
import GRDB
import Persistence
import Testing

@Suite("TrackRepositoryRootTests")
struct TrackRepositoryRootTests {
    private func seedRoot(
        _ repo: TrackRepository,
        root: String,
        count: Int,
        availability: Availability = .present
    ) throws {
        for index in 0 ..< count {
            _ = try repo.insert(TrackRecord(
                filePath: "\(root)/\(index).flac",
                title: "T\(index)",
                sortTitle: "T\(index)",
                availability: availability
            ))
        }
    }

    @Test("two roots: All Tracks == 5, root A == 2, root B == 3")
    func twoRootsPartition() throws {
        let appDB = try AppDatabase.makeEmpty()
        let repo = TrackRepository(appDB)
        try seedRoot(repo, root: "/Music/A", count: 2)
        try seedRoot(repo, root: "/Music/B", count: 3)

        let all = try repo.tracksPage(after: nil, limit: 100)
        #expect(all.items.count == 5)

        let pageA = try repo.tracksByRoot(rootPath: "/Music/A", after: nil, limit: 100)
        #expect(pageA.items.count == 2)
        #expect(pageA.items.allSatisfy { $0.filePath.hasPrefix("/Music/A/") })

        let pageB = try repo.tracksByRoot(rootPath: "/Music/B", after: nil, limit: 100)
        #expect(pageB.items.count == 3)
        #expect(pageB.items.allSatisfy { $0.filePath.hasPrefix("/Music/B/") })
    }

    @Test("a root prefix never matches a sibling sharing its name prefix")
    func prefixDoesNotMatchSibling() throws {
        let appDB = try AppDatabase.makeEmpty()
        let repo = TrackRepository(appDB)
        try seedRoot(repo, root: "/Music/A", count: 2)
        try seedRoot(repo, root: "/Music/Album", count: 4)

        let pageA = try repo.tracksByRoot(rootPath: "/Music/A", after: nil, limit: 100)
        #expect(pageA.items.count == 2)
        #expect(pageA.items.allSatisfy { $0.filePath.hasPrefix("/Music/A/") })
    }

    @Test("a trailing slash in the root path is normalised")
    func trailingSlashNormalised() throws {
        let appDB = try AppDatabase.makeEmpty()
        let repo = TrackRepository(appDB)
        try seedRoot(repo, root: "/Music/A", count: 2)

        let page = try repo.tracksByRoot(rootPath: "/Music/A/", after: nil, limit: 100)
        #expect(page.items.count == 2)
    }

    @Test("tracksByRoot is keyset-paginated: ascending id, each row exactly once")
    func keysetPaginates() throws {
        let appDB = try AppDatabase.makeEmpty()
        let repo = TrackRepository(appDB)
        try seedRoot(repo, root: "/Music/B", count: 3)

        var ids: [Int64] = []
        var cursor: PageCursor<Int64>?
        var pages = 0
        repeat {
            let page = try repo.tracksByRoot(rootPath: "/Music/B", after: cursor, limit: 1)
            ids.append(contentsOf: page.items.compactMap(\.id))
            cursor = page.nextCursor
            pages += 1
        } while cursor != nil && pages < 10

        #expect(ids.count == 3)
        #expect(Set(ids).count == 3)
        #expect(ids == ids.sorted())
    }

    @Test("rootSummary tallies availability under a root")
    func rootSummaryTally() throws {
        let appDB = try AppDatabase.makeEmpty()
        let repo = TrackRepository(appDB)
        try seedRoot(repo, root: "/Music/A", count: 2)
        try seedRoot(repo, root: "/Music/B", count: 3)

        let summaryA = try repo.rootSummary(rootPath: "/Music/A")
        #expect(summaryA.total == 2)
        #expect(summaryA.present == 2)
        #expect(summaryA.hasTracks)
        #expect(!summaryA.isFullyUnavailable)

        let summaryB = try repo.rootSummary(rootPath: "/Music/B")
        #expect(summaryB.total == 3)
        #expect(summaryB.present == 3)
    }

    @Test("removing a root keeps its rows as missing and its node badged")
    func removedRootSurvivesAsMissing() throws {
        let appDB = try AppDatabase.makeEmpty()
        let repo = TrackRepository(appDB)
        try seedRoot(repo, root: "/Music/A", count: 2)
        try seedRoot(repo, root: "/Music/B", count: 3)

        try appDB.writer.write { db in
            try db.execute(
                sql: "UPDATE track SET availability = ? WHERE filePath LIKE '/Music/B/%'",
                arguments: [Availability.missing.rawValue]
            )
        }

        let pageB = try repo.tracksByRoot(rootPath: "/Music/B", after: nil, limit: 100)
        #expect(pageB.items.count == 3)
        #expect(pageB.items.allSatisfy { $0.availability == .missing })

        let summaryB = try repo.rootSummary(rootPath: "/Music/B")
        #expect(summaryB.total == 3)
        #expect(summaryB.present == 0)
        #expect(summaryB.missing == 3)
        #expect(summaryB.isFullyUnavailable)

        let summaryA = try repo.rootSummary(rootPath: "/Music/A")
        #expect(summaryA.present == 2)
        #expect(!summaryA.isFullyUnavailable)
    }
}
