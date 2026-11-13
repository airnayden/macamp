// The DETERMINISTIC performance gate for the folder-tree queries.
//
// A wall-clock assertion cannot be trusted here: `swift test --parallel` runs
// sibling suites concurrently, and `.serialized` only orders tests WITHIN a suite
// (the repo's own `ZeroAllocTapTests` is `.serialized` and still documented flaky
// under `--parallel`). So the thing actually at risk — **sargability** — is
// asserted directly instead: `EXPLAIN QUERY PLAN` over the exact statement
// production runs, arguments included, must report a SEARCH through the v10
// `track_on_filePath_customPosition` index and never a full `SCAN track`.
//
// This is contention-free, so it lives in the normal suite with the small
// fixture. The wall-clock numbers are evidence-only and live in the env-gated
// `FolderTreePerfTests`.
import Foundation
import GRDB
@testable import Persistence
import Testing

@Suite("FolderTreeQueryPlanTests")
struct FolderTreeQueryPlanTests {
    @Test("childFolders seeks the filePath index instead of scanning track")
    func childFoldersIsSargable() throws {
        let harness = try FolderTreeHarness()
        try harness.seedTree()

        let details = try harness.database.writer.read { db in
            let statement = try TrackRepository.childFoldersStatement(
                db,
                profileId: ProfileRecord.guestID,
                parentPath: "/Music/Root"
            )
            return try folderTreeQueryPlan(db, statement)
        }

        print("childFolders EXPLAIN QUERY PLAN:\n\(details.joined(separator: "\n"))")
        #expect(usesFilePathIndex(details), "expected a filePath index seek, got: \(details)")
        #expect(!scansTrackTable(details), "expected no full track scan, got: \(details)")
    }

    @Test("childFolders stays sargable once a profile's roots narrow it further")
    func childFoldersIsSargableUnderVisibilityScoping() throws {
        let harness = try FolderTreeHarness()
        let alex = try harness.makeProfile(named: "Alex")
        try harness.roots.addRoot(profileId: ProfileRecord.guestID, path: "/Music/Root")
        try harness.roots.addRoot(profileId: alex, path: "/Music/Second")
        try harness.seedTree()

        let details = try harness.database.writer.read { db in
            let statement = try TrackRepository.childFoldersStatement(
                db,
                profileId: ProfileRecord.guestID,
                parentPath: "/Music/Root"
            )
            return try folderTreeQueryPlan(db, statement)
        }

        print("childFolders (visibility-scoped) EXPLAIN QUERY PLAN:\n\(details.joined(separator: "\n"))")
        #expect(usesFilePathIndex(details), "expected a filePath index seek, got: \(details)")
        #expect(!scansTrackTable(details), "expected no full track scan, got: \(details)")
    }

    @Test("hasSubfolders seeks the filePath index instead of scanning track")
    func hasSubfoldersIsSargable() throws {
        let harness = try FolderTreeHarness()
        let alex = try harness.makeProfile(named: "Alex")
        try harness.roots.addRoot(profileId: ProfileRecord.guestID, path: "/Music/Root")
        try harness.roots.addRoot(profileId: alex, path: "/Music/Second")
        try harness.seedTree()

        let details = try harness.database.writer.read { db in
            let statement = try TrackRepository.hasSubfoldersStatement(
                db,
                profileId: ProfileRecord.guestID,
                rootPath: "/Music/Root"
            )
            return try folderTreeQueryPlan(db, statement)
        }

        print("hasSubfolders EXPLAIN QUERY PLAN:\n\(details.joined(separator: "\n"))")
        #expect(usesFilePathIndex(details), "expected a filePath index seek, got: \(details)")
        #expect(!scansTrackTable(details), "expected no full track scan, got: \(details)")
    }

    @Test("tracksDirectlyIn seeks the filePath index on both the first and a resumed page")
    func tracksDirectlyInIsSargable() throws {
        let harness = try FolderTreeHarness()
        try harness.seedTree()

        let plans = try harness.database.writer.read { db -> [String: [String]] in
            let first = try TrackRepository.tracksDirectlyInStatement(
                db,
                profileId: ProfileRecord.guestID,
                dirPath: "/Music/Root",
                after: nil,
                limit: 100
            )
            let resumed = try TrackRepository.tracksDirectlyInStatement(
                db,
                profileId: ProfileRecord.guestID,
                dirPath: "/Music/Root",
                after: PageCursor(key: "anchor", id: 1),
                limit: 100
            )
            let firstPlan = try folderTreeQueryPlan(db, first)
            let resumedPlan = try folderTreeQueryPlan(db, resumed)
            return ["first": firstPlan, "resumed": resumedPlan]
        }

        for (label, details) in plans.sorted(by: { $0.key < $1.key }) {
            print("tracksDirectlyIn (\(label)) EXPLAIN QUERY PLAN:\n\(details.joined(separator: "\n"))")
            #expect(usesFilePathIndex(details), "\(label): expected a filePath index seek, got: \(details)")
            #expect(!scansTrackTable(details), "\(label): expected no full track scan, got: \(details)")
        }
    }
}

// MARK: - Plan helpers

/// The `detail` column of every `EXPLAIN QUERY PLAN` row for `statement`.
///
/// The statement is explained with its **real** bound arguments: SQLite's LIKE
/// optimization inspects the bound pattern, so explaining a re-typed copy without
/// arguments would prove nothing about what production runs.
private func folderTreeQueryPlan(_ db: Database, _ statement: FolderQueryStatement) throws -> [String] {
    try Row
        .fetchAll(
            db,
            sql: "EXPLAIN QUERY PLAN \(statement.sql)",
            arguments: StatementArguments(statement.arguments)
        )
        .map { row -> String in row["detail"] }
}

/// Whether any plan step seeks the v10 `(filePath COLLATE NOCASE, customPosition)`
/// index — the property the `LIKE … ESCAPE '\'` prefix predicate exists to buy.
private func usesFilePathIndex(_ details: [String]) -> Bool {
    details.contains { $0.contains("track_on_filePath_customPosition") }
}

/// Whether any plan step reads the whole `track` table. Matched precisely so
/// `SCAN trackSearch` (a different table) can never be mistaken for a regression.
private func scansTrackTable(_ details: [String]) -> Bool {
    details.contains { $0 == "SCAN track" || $0.hasPrefix("SCAN track ") }
}
