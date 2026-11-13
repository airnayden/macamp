import GRDB
import Models

/// The **folder-tree** reads: the immediate subfolders of a browsed directory, the
/// tracks sitting directly inside one, and a search narrowed to a folder subtree.
///
/// Every folder in the tree is derived from `track.filePath` alone — there is no
/// folder table and this file adds **no migration**. All three queries are
/// profile-scoped through ``LibraryVisibility`` (so a subfolder of another
/// profile's root resolves to nothing rather than leaking rows) and bounded:
/// ``TrackRepository/childFolders(profileId:parentPath:)`` returns one row per
/// immediate subfolder, ``TrackRepository/tracksDirectlyIn(profileId:dirPath:after:limit:sort:)``
/// is keyset-paginated, and ``TrackRepository/searchTracks(profileId:rootPath:query:limit:)``
/// is `LIMIT`-capped.
///
/// **Sargability is the load-bearing property.** Each query narrows the `track`
/// table with `filePath LIKE '<dir>/%' ESCAPE '\'`, which SQLite's LIKE
/// optimization rewrites into a range seek on the v10
/// `track_on_filePath_customPosition` index (`filePath COLLATE NOCASE,
/// customPosition`). A bare range predicate (`filePath >= p AND filePath < q`)
/// would compare under `BINARY` and could **not** use that `NOCASE` index, so it
/// is deliberately not used. `FolderTreeQueryTests` pins this with an
/// `EXPLAIN QUERY PLAN` assertion.
public extension TrackRepository {
    /// The immediate subfolders of `parentPath`, each with the **recursive** count
    /// of visible tracks anywhere beneath it.
    ///
    /// Folder names are the next path segment after `parentPath`, extracted in SQL
    /// (`substr` up to the first `/`) and aggregated with `GROUP BY`, so one query
    /// answers a whole tree level no matter how many tracks sit under it. A
    /// directory that holds only files (no subfolders) yields `[]`, as does a path
    /// that no visible track lives under — neither throws.
    ///
    /// Ordered by name, case-insensitively.
    func childFolders(
        profileId: Int64 = ProfileRecord.guestID,
        parentPath: String
    ) throws -> [FolderChildSummary] {
        let prefix = Self.directoryPrefix(parentPath)
        return try dbWriter.read { db in
            let statement = try Self.childFoldersStatement(db, profileId: profileId, parentPath: parentPath)
            let rows = try Row.fetchAll(db, sql: statement.sql, arguments: StatementArguments(statement.arguments))
            return rows.map { row in
                let name: String = row["segment"]
                let count: Int = row["trackCount"]
                let hasChildren: Bool = row["hasChildren"]
                let newestDateAdded: Double? = row["newestDateAdded"]
                return FolderChildSummary(
                    name: name,
                    path: prefix + name,
                    trackCount: count,
                    hasChildren: hasChildren,
                    newestDateAdded: newestDateAdded
                )
            }
        }
    }

    /// Whether any visible track beneath `rootPath` sits in a **subfolder** rather
    /// than directly in the folder itself.
    ///
    /// Exactly the answer a disclosure chevron needs, without materializing the
    /// child level: ``childFolders(profileId:parentPath:)`` aggregates every track
    /// in the subtree, while this stops at the first nested row. The sidebar probes
    /// it once per library root so a leaf root renders with no chevron on its FIRST
    /// frame instead of only after the user opens it. A path no visible track lives
    /// under is `false` — it does not throw.
    func hasSubfolders(
        profileId: Int64 = ProfileRecord.guestID,
        rootPath: String
    ) throws -> Bool {
        try dbWriter.read { db in
            let statement = try Self.hasSubfoldersStatement(db, profileId: profileId, rootPath: rootPath)
            let found = try Bool.fetchOne(
                db,
                sql: statement.sql,
                arguments: StatementArguments(statement.arguments)
            )
            return found ?? false
        }
    }

    /// One keyset page of the visible tracks whose file sits **directly** in
    /// `dirPath` — files in nested subfolders belong to those folders' own pages.
    ///
    /// Ordered by this profile's manual order for `dirPath` when it has
    /// drag-reordered that root (`folderTrackOrder`, exactly as ``tracksByRoot``
    /// reads it), then by `(sortTitle, id)`. A directory the profile never
    /// reordered — every subfolder, and any root without stored positions — has no
    /// order rows, so all of its rows share the un-positioned prefix and the page
    /// is a plain `(sortTitle, id)` keyset. A nonexistent path returns an empty
    /// page with a `nil` cursor.
    ///
    /// Passing a `sort` other than ``FolderFilesSort/manual`` replaces that key
    /// with a query-derived one — see ``folderFilesKeyset(for:)``. The manual order
    /// remains the default, because it is the only order a drag may rewrite.
    func tracksDirectlyIn(
        profileId: Int64 = ProfileRecord.guestID,
        dirPath: String,
        after cursor: PageCursor<String>? = nil,
        limit: Int = 100,
        sort: FolderFilesSort = .manual
    ) throws -> Page<TrackRecord, String> {
        let pageLimit = max(1, limit)
        return try dbWriter.read { db in
            let statement = try Self.tracksDirectlyInStatement(
                db,
                profileId: profileId,
                dirPath: dirPath,
                after: cursor,
                limit: pageLimit,
                sort: sort
            )
            let overFetched = try FolderTreeOrderedTrack.fetchAll(
                db,
                sql: statement.sql,
                arguments: StatementArguments(statement.arguments)
            )
            let page = makePage(from: overFetched, limit: pageLimit) { row in
                PageCursor(key: row.orderKey, id: row.track.id ?? 0)
            }
            return Page(items: page.items.map(\.track), nextCursor: page.nextCursor)
        }
    }

    /// Full-text search narrowed to one folder subtree, ranked by relevance.
    ///
    /// The same FTS5 pattern and BM25 `rank` ordering as the library-wide
    /// ``searchTracks(profileId:query:limit:)``, with the folder's escaped
    /// `filePath` prefix `AND`-ed in so only tracks beneath `rootPath` match. The
    /// result is `LIMIT`-capped, never a full fetch.
    func searchTracks(
        profileId: Int64 = ProfileRecord.guestID,
        rootPath: String,
        query: String,
        limit: Int = 50
    ) throws -> [TrackRecord] {
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: query) else { return [] }
        let pageLimit = max(1, limit)
        return try dbWriter.read { db in
            let visibility = try LibraryVisibility.predicate(db, profileId: profileId, column: "track.filePath")
            var arguments: [any DatabaseValueConvertible] = [
                pattern.rawPattern,
                Self.likePrefixPattern(forRoot: rootPath),
            ]
            arguments.append(contentsOf: visibility.arguments)
            arguments.append(pageLimit)
            return try TrackRecord.fetchAll(db, sql: """
            SELECT track.* FROM track
            JOIN trackSearch ON trackSearch.rowid = track.id
            WHERE trackSearch MATCH ?
              AND track.filePath LIKE ? ESCAPE '\\'
              AND \(visibility.sql)
            ORDER BY trackSearch.rank
            LIMIT ?
            """, arguments: StatementArguments(arguments))
        }
    }
}

// MARK: - Result types

/// One immediate subfolder of a browsed directory.
///
/// `trackCount` is **recursive** — every visible track anywhere beneath the
/// folder — because that is the number a collapsed tree row has to show.
/// `hasChildren` reports whether the folder itself holds subfolders, so a tree UI
/// can render (or withhold) a disclosure chevron without a second probe per row.
public struct FolderChildSummary: Sendable, Equatable, Hashable {
    /// The folder's own name — the path segment immediately after the parent.
    public let name: String
    /// The folder's absolute path (`<parent>/<name>`), the key every other
    /// folder-tree query takes.
    public let path: String
    /// Visible tracks anywhere beneath this folder, at any depth.
    public let trackCount: Int
    /// Whether this folder contains at least one subfolder that holds tracks.
    public let hasChildren: Bool
    /// The newest `track.dateAdded` anywhere beneath this folder, or `nil` when no
    /// track under it carries one. Derived per read (`MAX`), never stored — there
    /// is no folder table, so a folder has no date of its own.
    public let newestDateAdded: Double?

    public init(
        name: String,
        path: String,
        trackCount: Int,
        hasChildren: Bool,
        newestDateAdded: Double? = nil
    ) {
        self.name = name
        self.path = path
        self.trackCount = trackCount
        self.hasChildren = hasChildren
        self.newestDateAdded = newestDateAdded
    }
}

/// A folder-tree page row: the track plus the `String` sort key its cursor
/// resumes from, which must travel beside it because ``TrackRecord`` carries
/// neither a folder position nor the composed key.
struct FolderTreeOrderedTrack: FetchableRecord {
    let track: TrackRecord
    let orderKey: String

    init(row: Row) throws {
        track = try TrackRecord(row: row)
        let key: String? = row[TrackRepository.folderTreeOrderKeyColumn]
        orderKey = key ?? ""
    }
}

// MARK: - Statements

/// A composed SQL statement and its bound arguments.
///
/// The folder queries hand this out (rather than executing SQL built inline) so
/// `FolderTreeQueryTests` can run `EXPLAIN QUERY PLAN` over the **exact**
/// statement production runs, arguments included — the plan assertion would prove
/// nothing about a re-typed copy.
struct FolderQueryStatement {
    let sql: String
    let arguments: [any DatabaseValueConvertible]
}

extension TrackRepository {
    /// The alias ``folderTreeOrderKeySQL`` is selected under, so the page can read
    /// the key back without re-deriving it. `TrackRecord` ignores the extra column.
    static let folderTreeOrderKeyColumn = "folderTreeOrderKey"

    /// The folder-tree page's sort key — and, identically, its keyset cursor key.
    ///
    /// A zero-padded manual position followed by the sort title, so ONE `String`
    /// key expresses both orders: positioned rows lead in their stored order, and
    /// everything without a position shares the `Int64.max` prefix and falls back
    /// to `(sortTitle, id)`. The padding is fixed-width, so lexicographic
    /// comparison of the concatenation is exactly `(position, sortTitle)` — which
    /// is what lets the keyset cursor stay a single `String`. Positions written by
    /// ``updateFolderPositions(profileId:rootPath:_:)`` ascend from `0` and are
    /// never negative, so no sign ever breaks the padding. Requires the `fto` alias
    /// for `folderTrackOrder` to be joined for the (profile, root) pair.
    static let folderTreeOrderKeySQL = """
    printf('%020d', COALESCE(fto.position, \(unpositionedFolderOrderKey))) || COALESCE(track.sortTitle, '')
    """

    /// The directory prefix a folder query matches against: the path with any
    /// trailing slashes stripped and exactly one appended, so `/Music` and
    /// `/Music/` address the same folder. Kept in lockstep with
    /// ``likePrefixPattern(forRoot:)``, which escapes this same string.
    static func directoryPrefix(_ path: String) -> String {
        var prefix = path
        while prefix.hasSuffix("/") {
            prefix.removeLast()
        }
        return prefix + "/"
    }

    /// The immediate-subfolder aggregate over one directory.
    ///
    /// The inner select narrows `track` by the sargable escaped prefix and
    /// projects each row's path remainder once; the outer select splits that
    /// remainder at the first `/` and groups by the segment. Rows with no `/` left
    /// are the directory's own files and are excluded — they are
    /// ``tracksDirectlyIn(profileId:dirPath:after:limit:sort:)``'s job.
    static func childFoldersStatement(
        _ db: Database,
        profileId: Int64,
        parentPath: String
    ) throws -> FolderQueryStatement {
        let visibility = try LibraryVisibility.predicate(db, profileId: profileId, column: "track.filePath")
        var arguments: [any DatabaseValueConvertible] = [
            directoryPrefix(parentPath),
            likePrefixPattern(forRoot: parentPath),
        ]
        arguments.append(contentsOf: visibility.arguments)
        let sql = """
        SELECT
          substr(entry.rest, 1, instr(entry.rest, '/') - 1) AS segment,
          COUNT(*) AS trackCount,
          MAX(instr(substr(entry.rest, instr(entry.rest, '/') + 1), '/') > 0) AS hasChildren,
          MAX(entry.dateAdded) AS newestDateAdded
        FROM (
          SELECT substr(track.filePath, length(?) + 1) AS rest, track.dateAdded AS dateAdded
          FROM track
          WHERE track.filePath LIKE ? ESCAPE '\\'
            AND \(visibility.sql)
        ) AS entry
        WHERE instr(entry.rest, '/') > 0
        GROUP BY segment
        ORDER BY segment COLLATE NOCASE
        """
        return FolderQueryStatement(sql: sql, arguments: arguments)
    }

    /// The existence probe behind a root's disclosure chevron.
    ///
    /// The same sargable escaped prefix as ``childFoldersStatement(_:profileId:parentPath:)``
    /// narrows `track`; each matched path's remainder is then tested for a `/`,
    /// which is precisely "this track lives in a subfolder, not in the folder
    /// itself". `EXISTS` stops at the first such row, so a root that nests answers
    /// from one index seek instead of the child level's whole `GROUP BY`.
    static func hasSubfoldersStatement(
        _ db: Database,
        profileId: Int64,
        rootPath: String
    ) throws -> FolderQueryStatement {
        let visibility = try LibraryVisibility.predicate(db, profileId: profileId, column: "track.filePath")
        var arguments: [any DatabaseValueConvertible] = [
            likePrefixPattern(forRoot: rootPath),
            directoryPrefix(rootPath),
        ]
        arguments.append(contentsOf: visibility.arguments)
        let sql = """
        SELECT EXISTS(
          SELECT 1 FROM track
          WHERE track.filePath LIKE ? ESCAPE '\\'
            AND instr(substr(track.filePath, length(?) + 1), '/') > 0
            AND \(visibility.sql)
          LIMIT 1
        )
        """
        return FolderQueryStatement(sql: sql, arguments: arguments)
    }

    /// The keyset page of the tracks sitting directly in one directory.
    ///
    /// `LIKE '<dir>/%'` seeks the index; `NOT LIKE '<dir>/%/%'` then drops
    /// everything nested deeper. Both patterns are escaped, so a folder literally
    /// named `100%hits_x` matches itself rather than acting as a wildcard.
    ///
    /// `sort` swaps only the key expression and the direction it runs in; the
    /// `folderTrackOrder` join stays in place for every sort so the statement has
    /// one shape and one argument order. Under a query-derived sort the join
    /// simply contributes nothing — a `LEFT JOIN` on that table's composite
    /// primary key, which SQLite answers from the index.
    static func tracksDirectlyInStatement(
        _ db: Database,
        profileId: Int64,
        dirPath: String,
        after cursor: PageCursor<String>?,
        limit: Int,
        sort: FolderFilesSort = .manual
    ) throws -> FolderQueryStatement {
        let visibility = try LibraryVisibility.predicate(db, profileId: profileId, column: "track.filePath")
        let subtreePattern = likePrefixPattern(forRoot: dirPath)
        let keyset = folderFilesKeyset(for: sort)
        var arguments: [any DatabaseValueConvertible] = [
            profileId,
            canonicalRootKey(dirPath),
            subtreePattern,
            subtreePattern + "/%",
        ]
        arguments.append(contentsOf: visibility.arguments)
        var sql = """
        SELECT track.*, \(keyset.keySQL) AS \(folderTreeOrderKeyColumn) FROM track
        LEFT JOIN folderTrackOrder fto
          ON (fto.profileId = ? AND fto.rootPath = ? AND fto.trackId = track.id)
        WHERE track.filePath LIKE ? ESCAPE '\\'
          AND track.filePath NOT LIKE ? ESCAPE '\\'
          AND \(visibility.sql)
        """
        if let cursor {
            sql += "\n  AND (\(keyset.keySQL), track.id) \(keyset.comparison) (?, ?)"
            arguments.append(cursor.key)
            arguments.append(cursor.id)
        }
        sql += "\nORDER BY \(keyset.keySQL)\(keyset.orderSuffix), track.id\(keyset.orderSuffix)\nLIMIT ?"
        arguments.append(limit + 1)
        return FolderQueryStatement(sql: sql, arguments: arguments)
    }
}
