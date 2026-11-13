// The write half of the folder-order contract: `updateFolderPositions`.
//
// The user only ever drags rows inside the loaded window, so the write API must
// (a) seed positions for the ENTIRE root the first time a root is reordered and
// (b) apply the user's move — both in ONE transaction, so an interrupted first
// reorder rolls back to "no custom order" rather than a half-numbered root.
// Favourites' `profileTrackState.customPosition` must never be touched.
import Foundation
import GRDB
import Persistence
import Testing

@Suite("FolderTrackOrderWriteTests")
struct FolderTrackOrderWriteTests {
    private let root = "/Music/A"

    // MARK: - Fixtures

    private func seedRoot(_ repo: TrackRepository, root: String, count: Int, from start: Int = 0) throws -> [Int64] {
        try (start ..< start + count).map { index in
            let inserted = try repo.insert(TrackRecord(
                filePath: "\(root)/\(index).flac",
                title: "T\(index)",
                sortTitle: "t\(index)"
            ))
            return inserted.id ?? 0
        }
    }

    private func orderRows(_ database: AppDatabase, rootPath: String) throws -> [FolderTrackOrderRecord] {
        try database.writer.read { db in
            try FolderTrackOrderRecord
                .filter(FolderTrackOrderRecord.Columns.rootPath == rootPath)
                .order(FolderTrackOrderRecord.Columns.position)
                .fetchAll(db)
        }
    }

    private func profileStateRows(_ database: AppDatabase) throws -> [Row] {
        try database.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM profileTrackState ORDER BY profileId, trackId")
        }
    }

    private func pagedIDs(_ repo: TrackRepository, rootPath: String, pageSize: Int) throws -> [Int64] {
        var ids: [Int64] = []
        var cursor: PageCursor<Int64>?
        var pages = 0
        repeat {
            let page = try repo.tracksByRoot(rootPath: rootPath, after: cursor, limit: pageSize)
            ids.append(contentsOf: page.items.compactMap(\.id))
            cursor = page.nextCursor
            pages += 1
        } while cursor != nil && pages < 100
        return ids
    }

    private func updates(_ orderedIds: [Int64]) -> [(trackId: Int64, position: Int)] {
        orderedIds.enumerated().map { (trackId: $1, position: $0) }
    }

    // MARK: - Backfill + scale

    @Test("a page-1 reorder of a 250-track root backfills the whole root and pages exactly once each")
    func firstReorderBackfillsTheWholeRoot() async throws {
        let database = try AppDatabase.makeEmpty()
        let repo = TrackRepository(database)
        let ids = try seedRoot(repo, root: root, count: 250)

        var window = try repo.tracksByRoot(rootPath: root, after: nil, limit: 100).items.compactMap(\.id)
        window.insert(window.removeLast(), at: 0)
        try await repo.updateFolderPositions(rootPath: root, updates(window))

        let rows = try orderRows(database, rootPath: root)
        #expect(rows.count == 250)
        #expect(rows.map(\.position) == Array(0 ..< 250))
        let paged = try pagedIDs(repo, rootPath: root, pageSize: 100)
        #expect(paged.count == 250)
        #expect(Set(paged).count == 250)
        #expect(Array(paged.prefix(100)) == window)
        #expect(Array(paged.dropFirst(100)) == Array(ids.dropFirst(100)))
    }

    @Test("the reorder survives a fresh repository over the same database")
    func reorderPersistsAcrossRelaunch() async throws {
        let database = try AppDatabase.makeEmpty()
        let ids = try seedRoot(TrackRepository(database), root: root, count: 5)
        try await TrackRepository(database).updateFolderPositions(rootPath: root, updates(ids.reversed()))

        let reopened = TrackRepository(database)
        let page = try reopened.tracksByRoot(rootPath: root, after: nil, limit: 100)

        #expect(page.items.compactMap(\.id) == Array(ids.reversed()))
    }

    @Test("an interrupted first reorder leaves NO partial order rows")
    func failedBackfillRollsBackCompletely() async throws {
        let database = try AppDatabase.makeEmpty()
        let repo = TrackRepository(database)
        let ids = try seedRoot(repo, root: root, count: 20)
        let poisoned = updates(ids.reversed()) + [(trackId: 999_999, position: 99)]

        await #expect(throws: (any Error).self) {
            try await repo.updateFolderPositions(rootPath: root, poisoned)
        }

        #expect(try orderRows(database, rootPath: root).isEmpty)
        let page = try repo.tracksByRoot(rootPath: root, after: nil, limit: 100)
        #expect(page.items.compactMap(\.id) == ids)
    }

    // MARK: - Favourites independence (both directions)

    @Test("a folder reorder leaves every profileTrackState row byte-identical")
    func folderReorderLeavesFavouritesUntouched() async throws {
        let database = try AppDatabase.makeEmpty()
        let repo = TrackRepository(database)
        let ids = try seedRoot(repo, root: root, count: 5)
        try await repo.updateCustomPositions(updates(ids))
        for trackId in ids {
            try await repo.setFavourite(trackId: trackId, isFavourite: true)
        }
        let before = try profileStateRows(database).map(\.description)
        let favouritesBefore = try repo.favouriteTracks(profileId: ProfileRecord.guestID).compactMap(\.track.id)

        try await repo.updateFolderPositions(rootPath: root, updates(ids.reversed()))

        #expect(try profileStateRows(database).map(\.description) == before)
        #expect(try repo.favouriteTracks(profileId: ProfileRecord.guestID).compactMap(\.track.id) == favouritesBefore)
    }

    @Test("a Favourites reorder leaves folderTrackOrder and the folder order untouched")
    func favouritesReorderLeavesFolderOrderUntouched() async throws {
        let database = try AppDatabase.makeEmpty()
        let repo = TrackRepository(database)
        let ids = try seedRoot(repo, root: root, count: 5)
        try await repo.updateFolderPositions(rootPath: root, updates(ids.reversed()))
        let before = try orderRows(database, rootPath: root)

        try await repo.updateCustomPositions(updates(ids))

        #expect(try orderRows(database, rootPath: root) == before)
        let page = try repo.tracksByRoot(rootPath: root, after: nil, limit: 100)
        #expect(page.items.compactMap(\.id) == Array(ids.reversed()))
    }

    // MARK: - Scoping

    @Test("a reorder is invisible to another profile")
    func reorderIsScopedToTheProfile() async throws {
        let database = try AppDatabase.makeEmpty()
        let repo = TrackRepository(database)
        let otherId = try await database.writer.write { db -> Int64 in
            var other = ProfileRecord(name: "Other")
            try other.insert(db)
            return other.id ?? 0
        }
        let ids = try seedRoot(repo, root: root, count: 4)

        try await repo.updateFolderPositions(rootPath: root, updates(ids.reversed()))

        let guestPage = try repo.tracksByRoot(rootPath: root, after: nil, limit: 100)
        let otherPage = try repo.tracksByRoot(profileId: otherId, rootPath: root, after: nil, limit: 100)
        #expect(guestPage.items.compactMap(\.id) == Array(ids.reversed()))
        #expect(otherPage.items.compactMap(\.id) == ids)
    }

    @Test("reordering an outer root leaves a nested root's order untouched, and vice versa")
    func reorderIsScopedToTheRoot() async throws {
        let database = try AppDatabase.makeEmpty()
        let repo = TrackRepository(database)
        let outer = try seedRoot(repo, root: "/Music", count: 2)
        let nested = try seedRoot(repo, root: "/Music/Jazz", count: 3)

        try await repo.updateFolderPositions(rootPath: "/Music/Jazz", updates(nested.reversed()))
        let nestedRows = try orderRows(database, rootPath: "/Music/Jazz")
        try await repo.updateFolderPositions(rootPath: "/Music", updates((outer + nested).reversed()))

        #expect(try orderRows(database, rootPath: "/Music/Jazz") == nestedRows)
        let nestedPage = try repo.tracksByRoot(rootPath: "/Music/Jazz", after: nil, limit: 100)
        #expect(nestedPage.items.compactMap(\.id) == Array(nested.reversed()))
        let outerPage = try repo.tracksByRoot(rootPath: "/Music", after: nil, limit: 100)
        #expect(outerPage.items.compactMap(\.id) == Array((outer + nested).reversed()))
    }

    @Test("tracks the scanner adds after a reorder append last, in trackId order")
    func scannerAddedTracksAppendAfterAReorder() async throws {
        let database = try AppDatabase.makeEmpty()
        let repo = TrackRepository(database)
        let ids = try seedRoot(repo, root: root, count: 5)
        try await repo.updateFolderPositions(rootPath: root, updates(ids.reversed()))

        let scanned = try seedRoot(repo, root: root, count: 3, from: 100)

        let paged = try pagedIDs(repo, rootPath: root, pageSize: 2)
        #expect(paged == Array(ids.reversed()) + scanned)
        #expect(Set(paged).count == ids.count + scanned.count)
    }
}
