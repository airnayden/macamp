// Query-level proof that `tracksByRoot` renders the profile's manual folder order
// from the v15 `folderTrackOrder` table.
//
// These tests seed `folderTrackOrder` with raw SQL rather than through the
// repository write API, so they pin the READ contract on its own: ordering by
// `(position IS NULL, position, trackId)`, a keyset cursor built from that SAME
// compound key, and complete independence from Favourites'
// `profileTrackState.customPosition`.
import Foundation
import GRDB
import Persistence
import Testing

@Suite("FolderTrackOrderQueryTests")
struct FolderTrackOrderQueryTests {
    // MARK: - Fixtures

    private func seedRoot(_ repo: TrackRepository, root: String, count: Int) throws -> [Int64] {
        try (0 ..< count).map { index in
            let inserted = try repo.insert(TrackRecord(
                filePath: "\(root)/\(index).flac",
                title: "T\(index)",
                sortTitle: "t\(index)"
            ))
            return inserted.id ?? 0
        }
    }

    /// Writes `folderTrackOrder` rows directly, bypassing the repository write API.
    private func storeOrder(
        _ database: AppDatabase,
        profileId: Int64 = ProfileRecord.guestID,
        rootPath: String,
        _ orderedIds: [Int64]
    ) throws {
        try database.writer.write { db in
            for (position, trackId) in orderedIds.enumerated() {
                try db.execute(sql: """
                INSERT INTO folderTrackOrder (profileId, rootPath, trackId, position)
                VALUES (?, ?, ?, ?)
                """, arguments: [profileId, rootPath, trackId, position])
            }
        }
    }

    /// Walks every keyset page of a root, returning the track ids in page order.
    private func pagedIDs(
        _ repo: TrackRepository,
        profileId: Int64 = ProfileRecord.guestID,
        rootPath: String,
        pageSize: Int
    ) throws -> [Int64] {
        var ids: [Int64] = []
        var cursor: PageCursor<Int64>?
        var pages = 0
        repeat {
            let page = try repo.tracksByRoot(
                profileId: profileId,
                rootPath: rootPath,
                after: cursor,
                limit: pageSize
            )
            ids.append(contentsOf: page.items.compactMap(\.id))
            cursor = page.nextCursor
            pages += 1
        } while cursor != nil && pages < 100
        return ids
    }

    // MARK: - Ordering

    @Test("the stored folder order — not track.id — drives the page")
    func folderPageHonoursStoredOrder() throws {
        let database = try AppDatabase.makeEmpty()
        let repo = TrackRepository(database)
        let ids = try seedRoot(repo, root: "/Music/A", count: 4)
        try storeOrder(database, rootPath: "/Music/A", ids.reversed())

        let page = try repo.tracksByRoot(rootPath: "/Music/A", after: nil, limit: 100)

        #expect(page.items.compactMap(\.id) == Array(ids.reversed()))
    }

    @Test("a trailing slash resolves to the same stored order")
    func trailingSlashResolvesToTheSameOrder() throws {
        let database = try AppDatabase.makeEmpty()
        let repo = TrackRepository(database)
        let ids = try seedRoot(repo, root: "/Music/A", count: 3)
        try storeOrder(database, rootPath: "/Music/A", ids.reversed())

        let page = try repo.tracksByRoot(rootPath: "/Music/A/", after: nil, limit: 100)

        #expect(page.items.compactMap(\.id) == Array(ids.reversed()))
    }

    @Test("scanner-added tracks with no order row append AFTER the positioned rows")
    func unpositionedTracksAppendAfterPositionedOnes() throws {
        let database = try AppDatabase.makeEmpty()
        let repo = TrackRepository(database)
        let seeded = try seedRoot(repo, root: "/Music/A", count: 3)
        try storeOrder(database, rootPath: "/Music/A", seeded.reversed())
        // The scanner adds two more files to the same root — no order rows for them.
        let scanned = try seedRoot(repo, root: "/Music/A/New", count: 2)

        let page = try repo.tracksByRoot(rootPath: "/Music/A", after: nil, limit: 100)

        #expect(page.items.compactMap(\.id) == Array(seeded.reversed()) + scanned)
    }

    // MARK: - Keyset pagination

    @Test("keyset pages over a custom order cover every row exactly once")
    func keysetPagingOverCustomOrderHasNoDuplicatesOrSkips() throws {
        let database = try AppDatabase.makeEmpty()
        let repo = TrackRepository(database)
        let ids = try seedRoot(repo, root: "/Music/A", count: 6)
        try storeOrder(database, rootPath: "/Music/A", ids.reversed())

        let paged = try pagedIDs(repo, rootPath: "/Music/A", pageSize: 2)

        #expect(paged == Array(ids.reversed()))
        #expect(Set(paged).count == ids.count)
    }

    @Test("keyset pages spanning the positioned/unpositioned boundary have no gaps")
    func keysetPagingAcrossTheUnpositionedBoundaryIsExact() throws {
        let database = try AppDatabase.makeEmpty()
        let repo = TrackRepository(database)
        let seeded = try seedRoot(repo, root: "/Music/A", count: 4)
        try storeOrder(database, rootPath: "/Music/A", seeded.reversed())
        let scanned = try seedRoot(repo, root: "/Music/A/New", count: 3)

        let paged = try pagedIDs(repo, rootPath: "/Music/A", pageSize: 2)

        #expect(paged == Array(seeded.reversed()) + scanned)
        #expect(Set(paged).count == seeded.count + scanned.count)
    }

    // MARK: - Isolation

    @Test("nested roots hold independent orders")
    func nestedRootsAreIndependent() throws {
        let database = try AppDatabase.makeEmpty()
        let repo = TrackRepository(database)
        let outer = try seedRoot(repo, root: "/Music", count: 2)
        let nested = try seedRoot(repo, root: "/Music/Jazz", count: 3)
        try storeOrder(database, rootPath: "/Music", (outer + nested).reversed())
        try storeOrder(database, rootPath: "/Music/Jazz", nested.reversed())

        let outerPage = try repo.tracksByRoot(rootPath: "/Music", after: nil, limit: 100)
        let nestedPage = try repo.tracksByRoot(rootPath: "/Music/Jazz", after: nil, limit: 100)

        #expect(outerPage.items.compactMap(\.id) == Array((outer + nested).reversed()))
        #expect(nestedPage.items.compactMap(\.id) == Array(nested.reversed()))
    }

    @Test("one profile's folder order is invisible to another")
    func folderOrderIsPerProfile() throws {
        let database = try AppDatabase.makeEmpty()
        let repo = TrackRepository(database)
        var other = ProfileRecord(name: "Other")
        try database.writer.write { db in try other.insert(db) }
        let otherId = try #require(other.id)
        let ids = try seedRoot(repo, root: "/Music/A", count: 3)
        try storeOrder(database, rootPath: "/Music/A", ids.reversed())

        let guestPage = try repo.tracksByRoot(rootPath: "/Music/A", after: nil, limit: 100)
        let otherPage = try repo.tracksByRoot(profileId: otherId, rootPath: "/Music/A", after: nil, limit: 100)

        #expect(guestPage.items.compactMap(\.id) == Array(ids.reversed()))
        #expect(otherPage.items.compactMap(\.id) == ids)
    }

    @Test("Favourites' customPosition no longer reorders a folder")
    func favouritesCustomPositionDoesNotReorderAFolder() throws {
        let database = try AppDatabase.makeEmpty()
        let repo = TrackRepository(database)
        let ids = try seedRoot(repo, root: "/Music/A", count: 3)
        try database.writer.write { db in
            for (position, trackId) in ids.reversed().enumerated() {
                try db.execute(sql: """
                INSERT INTO profileTrackState (profileId, trackId, isFavourite, customPosition)
                VALUES (?, ?, 1, ?)
                """, arguments: [ProfileRecord.guestID, trackId, position])
            }
        }

        let page = try repo.tracksByRoot(rootPath: "/Music/A", after: nil, limit: 100)

        #expect(page.items.compactMap(\.id) == ids)
    }
}
