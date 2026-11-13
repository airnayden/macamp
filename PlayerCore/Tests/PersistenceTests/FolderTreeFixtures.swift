// The shared fixture for the folder-tree query suites (`FolderTreeQueryTests`,
// `FolderTreeQueryPlanTests`, `FolderTreePerfTests`).
//
// Folders exist only as prefixes of `track.filePath`, so "seeding a tree" is just
// inserting tracks at the right paths — there is no folder table to populate.
import Foundation
import GRDB
import Persistence
import Testing

/// An in-memory database plus the repositories the folder-tree queries need.
struct FolderTreeHarness {
    let database: AppDatabase
    let tracks: TrackRepository
    let profiles: ProfileRepository
    let roots: LibraryRootRepository

    init() throws {
        let database = try AppDatabase.makeEmpty()
        self.database = database
        tracks = TrackRepository(database)
        profiles = ProfileRepository(database)
        roots = LibraryRootRepository(database)
    }

    /// `dateAdded` defaults to `nil`, so an unadorned seed leaves the column NULL —
    /// the "folder has no date" case the folder aggregates must report as `nil`.
    @discardableResult
    func seed(path: String, title: String, dateAdded: Double? = nil) throws -> Int64 {
        let record = try tracks.insert(TrackRecord(
            filePath: path,
            title: title,
            sortTitle: title.lowercased(),
            dateAdded: dateAdded
        ))
        return try #require(record.id)
    }

    /// The canonical fixture tree: `/Music/Root/a.mp3`, `/Music/Root/Sub/b.mp3`,
    /// `/Music/Root/Sub/Deep/c.mp3`, plus a second root at `/Music/Second/d.mp3`.
    func seedTree() throws {
        try seed(path: "/Music/Root/a.mp3", title: "Alpha")
        try seed(path: "/Music/Root/Sub/b.mp3", title: "Bravo")
        try seed(path: "/Music/Root/Sub/Deep/c.mp3", title: "Charlie")
        try seed(path: "/Music/Second/d.mp3", title: "Delta")
    }

    func makeProfile(named name: String) throws -> Int64 {
        let created = try profiles.create(ProfileRecord(name: name))
        return try #require(created.id)
    }

    /// Writes `folderTrackOrder` rows directly, bypassing the repository write API,
    /// so the READ contract is pinned on its own.
    func storeOrder(
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

    /// Bulk-seeds a `<root>/Disc<i>/Part<j>/<k>.mp3` tree in bounded batches, so a
    /// six-figure fixture never materialises as one array of records.
    func seedWideTree(root: String, discs: Int, partsPerDisc: Int, tracksPerPart: Int) throws {
        var batch: [TrackRecord] = []
        batch.reserveCapacity(5000)
        for disc in 0 ..< discs {
            for part in 0 ..< partsPerDisc {
                for index in 0 ..< tracksPerPart {
                    let title = String(format: "Track %03d-%03d-%03d", disc, part, index)
                    batch.append(TrackRecord(
                        filePath: "\(root)/Disc\(disc)/Part\(part)/\(index).mp3",
                        title: title,
                        sortTitle: title.lowercased()
                    ))
                    if batch.count == 5000 {
                        _ = try tracks.insertBatch(batch)
                        batch.removeAll(keepingCapacity: true)
                    }
                }
            }
        }
        if !batch.isEmpty {
            _ = try tracks.insertBatch(batch)
        }
    }
}
