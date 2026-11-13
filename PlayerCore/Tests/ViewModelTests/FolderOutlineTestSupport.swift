// Test doubles and fixtures for the main-window folder outline.
//
// Its own file (rather than `ViewModelTestSupport.swift`) so the outline work does
// not collide with concurrent edits to the shared support file — the
// `FolderReorderTestSupport.swift` precedent.
import Foundation
import Models
import Persistence
import ViewModels

/// The fixture tree every outline test browses:
///
/// ```
/// /Music/Root            a.flac, b.flac …
/// /Music/Root/Sub        c.flac …
/// /Music/Root/Sub/Deep   d.flac …
/// ```
enum FolderOutlineFixture {
    static let root = "/Music/Root"
    static let sub = "/Music/Root/Sub"
    static let deep = "/Music/Root/Sub/Deep"

    static func track(
        id: Int64,
        dir: String,
        name: String,
        genre: String? = nil,
        dateAdded: Double? = nil
    ) -> TrackRecord {
        TrackRecord(
            id: id,
            filePath: "\(dir)/\(name).flac",
            title: name,
            sortTitle: name,
            dateAdded: dateAdded,
            genre: genre
        )
    }

    static func child(
        _ path: String,
        name: String,
        trackCount: Int = 1,
        hasChildren: Bool = false,
        newestDateAdded: Double? = nil
    ) -> FolderChildSummary {
        FolderChildSummary(
            name: name,
            path: path,
            trackCount: trackCount,
            hasChildren: hasChildren,
            newestDateAdded: newestDateAdded
        )
    }
}

/// An in-memory ``FolderOutlineReading`` that keyset-pages a fixed tree and records
/// every call, so a test can prove a level loaded exactly once and that a folder
/// order write carried the permuted ids.
final class FakeFolderOutlineRepository: FolderOutlineReading, @unchecked Sendable {
    private let lock = NSLock()
    private var childrenByParent: [String: [FolderChildSummary]]
    private var filesByDir: [String: [TrackRecord]]
    private var childCalls: [String] = []
    private var fileCalls: [String] = []
    private var sorts: [FolderFilesSort] = []
    private var writes: [FolderOrderWrite] = []

    init(children: [String: [FolderChildSummary]] = [:], files: [String: [TrackRecord]] = [:]) {
        childrenByParent = children
        filesByDir = files
    }

    /// Every `childFolders` parent path, in call order.
    var childFolderCalls: [String] {
        lock.withLock { childCalls }
    }

    /// Every `tracksDirectlyIn` directory path, in call order.
    var trackPageCalls: [String] {
        lock.withLock { fileCalls }
    }

    /// Every `tracksDirectlyIn` sort, in the same call order as ``trackPageCalls``.
    var trackPageSorts: [FolderFilesSort] {
        lock.withLock { sorts }
    }

    var orderWrites: [FolderOrderWrite] {
        lock.withLock { writes }
    }

    func childFolders(profileId _: Int64, parentPath: String) throws -> [FolderChildSummary] {
        lock.withLock {
            childCalls.append(parentPath)
            return childrenByParent[parentPath] ?? []
        }
    }

    func tracksDirectlyIn(
        profileId _: Int64,
        dirPath: String,
        after cursor: PageCursor<String>?,
        limit: Int,
        sort: FolderFilesSort
    ) throws -> Page<TrackRecord, String> {
        lock.withLock {
            fileCalls.append(dirPath)
            sorts.append(sort)
            let all = Self.ordered(filesByDir[dirPath] ?? [], by: sort)
            var start = 0
            if let cursor, let index = all.firstIndex(where: { $0.id == cursor.id }) {
                start = index + 1
            }
            let remaining = Array(all.dropFirst(start))
            let pageLimit = max(1, limit)
            let items = Array(remaining.prefix(pageLimit))
            guard remaining.count > pageLimit, let last = items.last else {
                return Page(items: items, nextCursor: nil)
            }
            let key = Self.cursorKey(for: last, at: start + items.count - 1, sort: sort)
            return Page(items: items, nextCursor: PageCursor(key: key, id: last.id ?? 0))
        }
    }

    /// The seeded rows in the order the real query would return them.
    ///
    /// Ordering by ``TrackRepository/sortCursorKey(for:sort:)`` rather than by a
    /// hand-written comparator is the point: that function is the Swift mirror of
    /// the SQL key the page selects, orders by and resumes from, so this double
    /// cannot disagree with the database about which row comes first. `.manual`
    /// keeps the seeded order — a fake holds no `folderTrackOrder` rows to resolve.
    static func ordered(_ tracks: [TrackRecord], by sort: FolderFilesSort) -> [TrackRecord] {
        guard case let .sorted(folderSort) = sort else { return tracks }
        let ascending = folderSort.direction == .ascending
        return tracks.sorted { lhs, rhs in
            let lhsKey = TrackRepository.sortCursorKey(for: lhs, sort: sort)
            let rhsKey = TrackRepository.sortCursorKey(for: rhs, sort: sort)
            guard lhsKey == rhsKey else { return ascending ? lhsKey < rhsKey : lhsKey > rhsKey }
            return ascending ? (lhs.id ?? 0) < (rhs.id ?? 0) : (lhs.id ?? 0) > (rhs.id ?? 0)
        }
    }

    private static func cursorKey(for track: TrackRecord, at index: Int, sort: FolderFilesSort) -> String {
        switch sort {
        case .manual: String(format: "%020ld", index)
        case .sorted: TrackRepository.sortCursorKey(for: track, sort: sort)
        }
    }

    func updateFolderPositions(
        profileId: Int64,
        rootPath: String,
        _ updates: [(trackId: Int64, position: Int)]
    ) async throws {
        lock.withLock {
            writes.append(FolderOrderWrite(
                profileId: profileId,
                rootPath: rootPath,
                orderedTrackIds: updates.sorted { $0.position < $1.position }.map(\.trackId)
            ))
        }
    }
}

extension FolderOutlineRow {
    var folder: FolderOutlineFolder? {
        if case let .folder(value) = self { return value }
        return nil
    }

    var file: FolderOutlineFile? {
        if case let .file(value) = self { return value }
        return nil
    }
}
