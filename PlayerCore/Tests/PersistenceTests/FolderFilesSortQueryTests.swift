// Query-level proof of the sorted keyset variants of `tracksDirectlyIn`.
//
// A folder's direct files page by a `PageCursor<String>`, so each of the five
// orderings has to collapse into ONE lexicographically monotone key. Three
// properties are therefore pinned here, each of which breaks silently:
//
//  1. `.manual` still emits the statement that shipped before sorting existed —
//     asserted against the literal SQL captured from the pre-change code, not
//     merely against the row order it happens to produce.
//  2. Every sort walked end to end at `limit: 3` yields the whole directory in
//     the expected order, once per row. A key that is not monotone skips or
//     repeats rows only ACROSS a page boundary, so a single-page assertion
//     would pass on a broken key.
//  3. `TrackRepository.sortCursorKey` reproduces the SQL key for every row, so
//     a caller re-anchoring a window it mutated locally lands where the database
//     would have put it.
import Foundation
import GRDB
import Models
@testable import Persistence
import Testing

/// The browsed directory and its nine seeded files: seven dated, two undated.
///
/// Dates deliberately disagree with titles, so a date ordering that silently fell
/// back to the title key would show up as the wrong sequence rather than as a
/// coincidence.
private enum Fixture {
    static let dir = "/Music/Root"

    static let seeds: [(title: String, dateAdded: Double?)] = [
        ("Echo", 500),
        ("Alpha", 300),
        ("Golf", 100),
        ("Charlie", 700),
        ("India", 200),
        ("Bravo", 600),
        ("Foxtrot", 400),
        ("Delta", nil),
        ("Hotel", nil),
    ]

    static let byName = ["Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf", "Hotel", "India"]
    static let byNameDescending = Array(byName.reversed())

    /// Dated rows first, oldest to newest; the two undated rows last, tie-broken
    /// by ascending `track.id` (Delta was seeded before Hotel).
    static let byDateAdded = ["Golf", "India", "Alpha", "Foxtrot", "Echo", "Bravo", "Charlie", "Delta", "Hotel"]

    /// Dated rows newest to oldest; the undated rows still LAST, now tie-broken by
    /// descending `track.id` because the whole order is reversed.
    static let byDateAddedDescending = [
        "Charlie", "Bravo", "Echo", "Foxtrot", "Alpha", "India", "Golf", "Hotel", "Delta",
    ]

    static let allSorts: [FolderFilesSort] = [
        .manual,
        .sorted(FolderSort(key: .name, direction: .ascending)),
        .sorted(FolderSort(key: .name, direction: .descending)),
        .sorted(FolderSort(key: .dateAdded, direction: .ascending)),
        .sorted(FolderSort(key: .dateAdded, direction: .descending)),
    ]

    /// The statement `tracksDirectlyIn` produced before `sort` existed, captured
    /// verbatim from the pre-change code (`TrackRepository+Folders.swift` at
    /// `f7c0e77`). `AND 1` is the visibility predicate with no roots configured.
    static let baselineFirstPageSQL = """
    SELECT track.*, printf('%020d', COALESCE(fto.position, 9223372036854775807)) || COALESCE(track.sortTitle, '') AS folderTreeOrderKey FROM track
    LEFT JOIN folderTrackOrder fto
      ON (fto.profileId = ? AND fto.rootPath = ? AND fto.trackId = track.id)
    WHERE track.filePath LIKE ? ESCAPE '\\'
      AND track.filePath NOT LIKE ? ESCAPE '\\'
      AND 1
    ORDER BY printf('%020d', COALESCE(fto.position, 9223372036854775807)) || COALESCE(track.sortTitle, ''), track.id
    LIMIT ?
    """

    static let baselineResumedPageSQL = """
    SELECT track.*, printf('%020d', COALESCE(fto.position, 9223372036854775807)) || COALESCE(track.sortTitle, '') AS folderTreeOrderKey FROM track
    LEFT JOIN folderTrackOrder fto
      ON (fto.profileId = ? AND fto.rootPath = ? AND fto.trackId = track.id)
    WHERE track.filePath LIKE ? ESCAPE '\\'
      AND track.filePath NOT LIKE ? ESCAPE '\\'
      AND 1
      AND (printf('%020d', COALESCE(fto.position, 9223372036854775807)) || COALESCE(track.sortTitle, ''), track.id) > (?, ?)
    ORDER BY printf('%020d', COALESCE(fto.position, 9223372036854775807)) || COALESCE(track.sortTitle, ''), track.id
    LIMIT ?
    """
}

/// Everything one end-to-end page walk observed.
private struct PagedWalk {
    var titles: [String] = []
    var ids: [Int64] = []
    var pageCount = 0
    /// Cursor keys the page handed back that ``TrackRepository/sortCursorKey(for:sort:)``
    /// did not reproduce.
    var cursorMismatches: [String] = []
}

@Suite("FolderFilesSortQueryTests")
struct FolderFilesSortQueryTests {
    // MARK: - Fixtures

    @discardableResult
    private func seedDirectory(_ harness: FolderTreeHarness) throws -> [Int64] {
        try Fixture.seeds.enumerated().map { index, seed in
            try harness.seed(
                path: "\(Fixture.dir)/\(index).flac",
                title: seed.title,
                dateAdded: seed.dateAdded
            )
        }
    }

    private func makeHarness() throws -> FolderTreeHarness {
        let harness = try FolderTreeHarness()
        try seedDirectory(harness)
        return harness
    }

    /// Walks every keyset page of the directory under `sort`.
    private func walk(
        _ harness: FolderTreeHarness,
        sort: FolderFilesSort,
        pageSize: Int = 3
    ) throws -> PagedWalk {
        var walked = PagedWalk()
        var cursor: PageCursor<String>?
        repeat {
            let page = try harness.tracks.tracksDirectlyIn(
                dirPath: Fixture.dir,
                after: cursor,
                limit: pageSize,
                sort: sort
            )
            walked.titles.append(contentsOf: page.items.compactMap(\.title))
            walked.ids.append(contentsOf: page.items.compactMap(\.id))
            walked.pageCount += 1
            if let next = page.nextCursor, let last = page.items.last {
                let mirrored = TrackRepository.sortCursorKey(for: last, sort: sort)
                if mirrored != next.key {
                    walked.cursorMismatches.append("page \(walked.pageCount): \(next.key) != \(mirrored)")
                }
            }
            cursor = page.nextCursor
        } while cursor != nil && walked.pageCount < 20
        return walked
    }

    /// Rows whose selected `folderTreeOrderKey` disagrees with the Swift mirror.
    private func keyMismatches(_ harness: FolderTreeHarness, sort: FolderFilesSort) throws -> [String] {
        try harness.database.writer.read { db in
            let statement = try TrackRepository.tracksDirectlyInStatement(
                db,
                profileId: ProfileRecord.guestID,
                dirPath: Fixture.dir,
                after: nil,
                limit: 100,
                sort: sort
            )
            let rows = try Row.fetchAll(db, sql: statement.sql, arguments: StatementArguments(statement.arguments))
            return try rows.compactMap { row -> String? in
                let track = try TrackRecord(row: row)
                let selected: String = row[TrackRepository.folderTreeOrderKeyColumn] ?? ""
                let mirrored = TrackRepository.sortCursorKey(for: track, sort: sort)
                guard selected != mirrored else { return nil }
                return "\(track.title ?? "?"): SQL \(selected) != mirror \(mirrored)"
            }
        }
    }

    // MARK: - The manual order is untouched

    @Test("the manual sort emits the statement that shipped before sorting existed")
    func manualStatementIsByteIdenticalToTheBaseline() throws {
        let harness = try makeHarness()

        let statements = try harness.database.writer.read { db -> [String] in
            let first = try TrackRepository.tracksDirectlyInStatement(
                db,
                profileId: ProfileRecord.guestID,
                dirPath: Fixture.dir,
                after: nil,
                limit: 3,
                sort: .manual
            )
            let resumed = try TrackRepository.tracksDirectlyInStatement(
                db,
                profileId: ProfileRecord.guestID,
                dirPath: Fixture.dir,
                after: PageCursor(key: "anchor", id: 7),
                limit: 3,
                sort: .manual
            )
            return [first.sql, resumed.sql]
        }

        #expect(statements[0] == Fixture.baselineFirstPageSQL)
        #expect(statements[1] == Fixture.baselineResumedPageSQL)
    }

    @Test("the manual sort is what an unsorted call still returns")
    func manualMatchesTheDefaultArgument() throws {
        let harness = try makeHarness()

        let defaulted = try harness.tracks.tracksDirectlyIn(dirPath: Fixture.dir, limit: 100)
        let explicit = try harness.tracks.tracksDirectlyIn(dirPath: Fixture.dir, limit: 100, sort: .manual)

        #expect(defaulted.items.compactMap(\.title) == Fixture.byName)
        #expect(explicit.items.compactMap(\.id) == defaulted.items.compactMap(\.id))
    }

    @Test("a stored drag order still drives the manual sort")
    func storedFolderOrderStillDrivesTheManualSort() throws {
        let harness = try FolderTreeHarness()
        let ids = try seedDirectory(harness)
        try harness.storeOrder(rootPath: Fixture.dir, ids.reversed())

        let walked = try walk(harness, sort: .manual)

        #expect(walked.ids == Array(ids.reversed()))
        #expect(Set(walked.ids).count == ids.count)
    }

    // MARK: - Sorted keyset pages

    @Test("name pages ascending and descending cover every row exactly once")
    func namePagesCoverEveryRowExactlyOnce() throws {
        let harness = try makeHarness()

        let ascending = try walk(harness, sort: .sorted(FolderSort(key: .name, direction: .ascending)))
        let descending = try walk(harness, sort: .sorted(FolderSort(key: .name, direction: .descending)))

        #expect(ascending.titles == Fixture.byName)
        #expect(descending.titles == Fixture.byNameDescending)
        #expect(Set(ascending.ids).count == Fixture.seeds.count)
        #expect(Set(descending.ids).count == Fixture.seeds.count)
        #expect(ascending.pageCount == 3)
    }

    @Test("dateAdded pages put the undated rows LAST in both directions")
    func dateAddedPagesPutUndatedRowsLast() throws {
        let harness = try makeHarness()

        let ascending = try walk(harness, sort: .sorted(FolderSort(key: .dateAdded, direction: .ascending)))
        let descending = try walk(harness, sort: .sorted(FolderSort(key: .dateAdded, direction: .descending)))

        #expect(ascending.titles == Fixture.byDateAdded)
        #expect(descending.titles == Fixture.byDateAddedDescending)
        #expect(ascending.titles.suffix(2) == ["Delta", "Hotel"])
        #expect(descending.titles.suffix(2) == ["Hotel", "Delta"])
        #expect(Set(ascending.ids).count == Fixture.seeds.count)
        #expect(Set(descending.ids).count == Fixture.seeds.count)
    }

    @Test("no sort skips or repeats a row across a page boundary")
    func everySortPagesWithoutGapsOrDuplicates() throws {
        let harness = try makeHarness()

        for sort in Fixture.allSorts {
            let walked = try walk(harness, sort: sort)
            #expect(walked.ids.count == Fixture.seeds.count, "\(sort.rawValue) returned \(walked.ids.count) rows")
            #expect(Set(walked.ids).count == Fixture.seeds.count, "\(sort.rawValue) repeated a row")
            #expect(walked.pageCount == 3, "\(sort.rawValue) took \(walked.pageCount) pages")
        }
    }

    // MARK: - The Swift mirror of the SQL key

    @Test("sortCursorKey reproduces the selected folderTreeOrderKey for every row")
    func cursorKeyMirrorsTheSelectedKey() throws {
        let harness = try makeHarness()

        for sort in Fixture.allSorts {
            let mismatches = try keyMismatches(harness, sort: sort)
            #expect(mismatches.isEmpty, "\(sort.rawValue): \(mismatches)")
        }
    }

    @Test("sortCursorKey reproduces every cursor the pages hand back")
    func cursorKeyMirrorsEveryPageCursor() throws {
        let harness = try makeHarness()

        for sort in Fixture.allSorts {
            let walked = try walk(harness, sort: sort)
            #expect(walked.cursorMismatches.isEmpty, "\(sort.rawValue): \(walked.cursorMismatches)")
        }
    }
}
