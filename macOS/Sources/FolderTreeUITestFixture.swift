// FolderTreeUITestFixture — two library ROOTS of deliberately different shape, so the
// sidebar's Folders section has both a tree to expand and a leaf that must never
// offer one.
//
// The base UI-test fixture seeds two loose tracks and registers NO `libraryRoot` row,
// so `FolderSidebarViewModel` builds zero nodes and the Folders section never renders.
// Subfolders are derived from `track.filePath` (never a filesystem walk), so the row
// paths below are what put a child level under a root — and what leave the second root
// without one, which is the case a root's disclosure chevron has to get right before
// anything is expanded.
import Foundation
import GRDB
import Persistence

#if DEBUG
    enum FolderTreeUITestFixture {
        /// Launch-environment switch. Absent ⇒ this file changes nothing.
        static let environmentKey = "UITEST_SEED_FOLDER_TREE"
        static let rootFolderName = "Fixture Library"
        static let childFolderName = "Live Sets"
        static let siblingFolderName = "Rarities"
        static let leafRootFolderName = "Fixture Singles"
        static let rootTrackTitle = "Root Overture"
        static let childTrackTitle = "Nested Encore"
        static let siblingTrackTitle = "Attic Take"
        static let leafRootTrackTitle = "Loose Single"

        static func seed(into database: AppDatabase, directory: URL) throws {
            let directory = canonicalDirectory(directory)
            let root = directory.appendingPathComponent(rootFolderName, isDirectory: true)
            let child = root.appendingPathComponent(childFolderName, isDirectory: true)
            let sibling = root.appendingPathComponent(siblingFolderName, isDirectory: true)
            let leafRoot = directory.appendingPathComponent(leafRootFolderName, isDirectory: true)
            for folder in [root, child, sibling, leafRoot] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            try database.writer.write { db in
                for folder in [root, leafRoot] {
                    var record = LibraryRootRecord(
                        profileId: ProfileRecord.guestID,
                        path: folder.path
                    )
                    try record.insert(db)
                }
                try insertTrack(db, folder: root, title: rootTrackTitle)
                try insertTrack(db, folder: child, title: childTrackTitle)
                try insertTrack(db, folder: sibling, title: siblingTrackTitle)
                try insertTrack(db, folder: leafRoot, title: leafRootTrackTitle)
            }
        }

        private static func insertTrack(_ db: Database, folder: URL, title: String) throws {
            let fileURL = folder.appendingPathComponent("\(title).mp3")
            FileManager.default.createFile(atPath: fileURL.path, contents: Data())
            var record = TrackRecord(
                filePath: fileURL.path,
                title: title,
                sortTitle: title.lowercased(),
                artistName: "Fixture Artist",
                duration: 123,
                availability: .present
            )
            try record.insert(db)
        }

        /// Resolves the seed directory through `realpath(3)` — the SAME canonicalization
        /// ``LibraryAccessController`` applies to a stored root and then writes back.
        ///
        /// Foundation's `standardizedFileURL` *strips* a `/private` prefix rather than
        /// adding one, so a root seeded that way is rewritten to `/private/…` at launch
        /// while its tracks keep the `/tmp` (or `/var`) spelling. The root then prefix-
        /// matches nothing, `rootSummary` reports zero tracks, and the sidebar drops the
        /// whole Folders section. Canonicalising the base ONCE keeps roots and track
        /// paths in the one spelling the app agrees with; every path below is derived
        /// from it, so nothing else needs resolving.
        private static func canonicalDirectory(_ url: URL) -> URL {
            url.withUnsafeFileSystemRepresentation { pointer -> URL? in
                guard let pointer, let resolved = realpath(pointer, nil) else { return nil }
                defer { free(resolved) }
                return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            } ?? url
        }
    }
#endif
