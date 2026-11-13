import GRDB

/// The keyset-paginated, **profile-scoped** track-browsing surface.
///
/// Extracted from `TrackRepository.swift` so each file stays within the SwiftLint
/// file/type-body budgets. Every all-library query (`tracksPage`, `tracksByGenre`,
/// `recentlyAddedObservation`) filters to the tracks visible to the active
/// profile via ``LibraryVisibility`` — files under the profile's `libraryRoot`
/// paths, plus ownerless files under no configured root. Per-folder
/// (`tracksByRoot`) and per-album/artist queries are already narrowed by their
/// path/foreign-key, so they carry no separate visibility clause; `tracksByRoot`
/// additionally orders by the **profile's** manual folder order (via the
/// per-root `folderTrackOrder` table, see `TrackRepository+FolderOrder.swift`), so
/// the order is per-profile and per-root and never reads either the frozen
/// `track.customPosition` column or Favourites' `profileTrackState.customPosition`.
///
/// `profileId` defaults to ``ProfileRecord/guestID`` so pre-profile call sites
/// (and the CLI/tests) resolve to Guest unchanged.
public extension TrackRepository {
    /// One keyset page of the visible tracks, ordered by `(sortTitle, id)`.
    @_disfavoredOverload
    func tracksPage(
        profileId: Int64 = ProfileRecord.guestID,
        after cursor: PageCursor<String>? = nil,
        limit: Int = 100
    ) throws -> Page<TrackRecord, String> {
        try dbWriter.read { db in try Self.fetchTracksPage(db, profileId: profileId, after: cursor, limit: limit) }
    }

    /// One keyset page of the visible tracks, read on a GRDB reader off the calling actor.
    func tracksPage(
        profileId: Int64 = ProfileRecord.guestID,
        after cursor: PageCursor<String>? = nil,
        limit: Int = 100
    ) async throws -> Page<TrackRecord, String> {
        try await dbWriter
            .read { db in try Self.fetchTracksPage(db, profileId: profileId, after: cursor, limit: limit) }
    }

    /// One keyset page of the tracks beneath a library-root folder, ordered by this
    /// profile's manual order for that root when it has drag-reordered the folder,
    /// else by `id`. Tracks the scanner added after the reorder have no order row
    /// and follow the positioned ones, in `id` order.
    func tracksByRoot(
        profileId: Int64 = ProfileRecord.guestID,
        rootPath: String,
        after cursor: PageCursor<Int64>? = nil,
        limit: Int = 100
    ) throws -> Page<TrackRecord, Int64> {
        try dbWriter.read { db in
            try Self.fetchTracksByRoot(db, profileId: profileId, rootPath: rootPath, after: cursor, limit: limit)
        }
    }

    /// One keyset page of the visible tracks matching a genre filter.
    func tracksByGenre(
        profileId: Int64 = ProfileRecord.guestID,
        genre: String?,
        after cursor: PageCursor<Int64>? = nil,
        limit: Int = 100
    ) throws -> Page<TrackRecord, Int64> {
        try dbWriter.read { db in
            try Self.fetchTracksByGenre(db, profileId: profileId, genre: genre, after: cursor, limit: limit)
        }
    }

    /// One keyset page of the visible tracks whose `filePath` is one of `paths`,
    /// ordered by the same `(sortTitle, id)` key as the library list and carrying
    /// each row's profile-resolved favourite/counts (via `profileTrackState`).
    ///
    /// `paths` is split into chunks of ``pathChunkSize`` (SQLite's bound-variable
    /// ceiling); each chunk runs the same profile-scoped keyset query and the
    /// per-chunk pages are merge-sorted into one bounded page of `limit` rows — so a
    /// path set larger than the SQLite `IN (…)` limit pages without ever loading the
    /// whole `track` table. Resume the next page with a ``PageCursor`` built from the
    /// last row's `(track.sortTitle, track.id)`; an empty result means the end.
    func tracksByPaths(
        profileId: Int64 = ProfileRecord.guestID,
        paths: [String],
        after cursor: PageCursor<String>? = nil,
        limit: Int = 100
    ) throws -> [ProfileScopedTrack] {
        try dbWriter.read { db in
            try Self.fetchTracksByPaths(db, profileId: profileId, paths: paths, after: cursor, limit: limit)
        }
    }

    /// The number of visible tracks whose `filePath` is in `paths`, using the same
    /// profile-visibility predicate and chunk size as ``tracksByPaths``.
    func countTracksByPaths(
        profileId: Int64 = ProfileRecord.guestID,
        paths: [String]
    ) throws -> Int {
        try dbWriter.read { db in
            try Self.fetchTrackCountByPaths(db, profileId: profileId, paths: paths)
        }
    }

    /// One keyset page of an album's tracks, in physical playing order. Not
    /// visibility-filtered: a visible album (Task 7 scopes album visibility by its
    /// tracks) shows its whole tracklist.
    func tracksByAlbum(
        albumId: Int64,
        after cursor: PageCursor<Int64>? = nil,
        limit: Int = 100
    ) throws -> Page<TrackRecord, Int64> {
        try dbWriter.read { db in
            try TrackRecord
                .filter(TrackRecord.Columns.albumId == albumId)
                .filter(CueSuppression.notSuppressed)
                .fetchPage(
                    db,
                    sort: KeysetSort(keyExpressionSQL: "(COALESCE(discNumber, 0) * 100000 + COALESCE(trackNumber, 0))"),
                    after: cursor,
                    limit: limit,
                    cursorForLast: { PageCursor(key: Self.trackOrdinal($0), id: $0.id ?? 0) }
                )
        }
    }

    /// One keyset page of an artist's tracks, ordered by `(sortTitle, id)`.
    func tracksByArtist(
        artistId: Int64,
        after cursor: PageCursor<String>? = nil,
        limit: Int = 100
    ) throws -> Page<TrackRecord, String> {
        try dbWriter.read { db in
            try TrackRecord
                .filter(TrackRecord.Columns.artistId == artistId)
                .filter(CueSuppression.notSuppressed)
                .fetchPage(
                    db,
                    sort: KeysetSort(keyExpressionSQL: "COALESCE(sortTitle, '')"),
                    after: cursor,
                    limit: limit,
                    cursorForLast: { PageCursor(key: $0.sortTitle ?? "", id: $0.id ?? 0) }
                )
        }
    }

    /// A bounded observation of the profile's most recently added visible tracks.
    ///
    /// The request is `LIMIT`-capped so the observation never loads the whole
    /// `track` table, and it reads `libraryRoot` (through ``LibraryVisibility``) so
    /// a change to the profile's roots re-delivers a rescoped window.
    func recentlyAddedObservation(
        profileId: Int64 = ProfileRecord.guestID,
        limit: Int = 100
    ) -> ValueObservation<ValueReducers.Fetch<[TrackRecord]>> {
        let pageLimit = max(1, limit)
        return ValueObservation.tracking { db in
            let visibility = try LibraryVisibility.predicate(db, profileId: profileId)
            return try TrackRecord
                .filter(sql: visibility.sql, arguments: StatementArguments(visibility.arguments))
                .filter(CueSuppression.notSuppressed)
                .order(TrackRecord.Columns.dateAdded.desc)
                .limit(pageLimit)
                .fetchAll(db)
        }
    }

    /// Normalises a library-root path to an escaped `LIKE` prefix pattern
    /// (`<root>/%`), stripping trailing slashes and escaping `LIKE`
    /// metacharacters. Shared by the folder queries and ``LibraryVisibility``.
    static func likePrefixPattern(forRoot rootPath: String) -> String {
        var prefix = rootPath
        while prefix.hasSuffix("/") {
            prefix.removeLast()
        }
        prefix += "/"
        let escaped = prefix
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return escaped + "%"
    }
}

private extension TrackRepository {
    static func fetchTracksPage(
        _ db: Database,
        profileId: Int64,
        after cursor: PageCursor<String>?,
        limit: Int
    ) throws -> Page<TrackRecord, String> {
        let visibility = try LibraryVisibility.predicate(db, profileId: profileId)
        return try TrackRecord
            .filter(sql: visibility.sql, arguments: StatementArguments(visibility.arguments))
            .filter(CueSuppression.notSuppressed)
            .fetchPage(
                db,
                sort: KeysetSort(keyExpressionSQL: "COALESCE(sortTitle, '')"),
                after: cursor,
                limit: limit,
                cursorForLast: { PageCursor(key: $0.sortTitle ?? "", id: $0.id ?? 0) }
            )
    }

    static func fetchTracksByRoot(
        _ db: Database,
        profileId: Int64,
        rootPath: String,
        after cursor: PageCursor<Int64>?,
        limit: Int
    ) throws -> Page<TrackRecord, Int64> {
        let pageLimit = max(1, limit)
        var sql = """
        SELECT track.*, \(folderOrderKeySQL) AS \(folderOrderKeyColumn) FROM track
        LEFT JOIN folderTrackOrder fto
          ON (fto.profileId = ? AND fto.rootPath = ? AND fto.trackId = track.id)
        WHERE track.filePath LIKE ? ESCAPE '\\'
          AND \(CueSuppression.notSuppressedSQL(qualifier: "track"))
        """
        var arguments: [any DatabaseValueConvertible] = [
            profileId,
            canonicalRootKey(rootPath),
            likePrefixPattern(forRoot: rootPath),
        ]
        if let cursor {
            sql += "\n  AND (\(folderOrderKeySQL), track.id) > (?, ?)"
            arguments.append(cursor.key)
            arguments.append(cursor.id)
        }
        sql += "\nORDER BY \(folderOrderKeySQL), track.id\nLIMIT ?"
        arguments.append(pageLimit + 1)
        let overFetched = try FolderOrderedTrack.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        let page = makePage(from: overFetched, limit: pageLimit) { row in
            PageCursor(key: row.orderKey, id: row.track.id ?? 0)
        }
        return Page(items: page.items.map(\.track), nextCursor: page.nextCursor)
    }

    static func fetchTracksByGenre(
        _ db: Database,
        profileId: Int64,
        genre: String?,
        after cursor: PageCursor<Int64>?,
        limit: Int
    ) throws -> Page<TrackRecord, Int64> {
        let pageLimit = max(1, limit)
        let visibility = try LibraryVisibility.predicate(db, profileId: profileId)
        var request = genreFilteredRequest(genre: genre)
            .filter(sql: visibility.sql, arguments: StatementArguments(visibility.arguments))
            .filter(CueSuppression.notSuppressed)
        if let cursor {
            request = request.filter(TrackRecord.Columns.id > cursor.id)
        }
        let overFetched = try request
            .order(TrackRecord.Columns.id)
            .limit(pageLimit + 1)
            .fetchAll(db)
        return makePage(from: overFetched, limit: pageLimit) { track in
            PageCursor(key: track.id ?? 0, id: track.id ?? 0)
        }
    }

    static func genreFilteredRequest(genre: String?) -> QueryInterfaceRequest<TrackRecord> {
        guard let genre else { return TrackRecord.all() }
        if genre.isEmpty {
            return TrackRecord.filter(sql: "(genre IS NULL OR genre = '')")
        }
        return TrackRecord.filter(sql: "(genre = ? COLLATE NOCASE)", arguments: [genre])
    }

    static func trackOrdinal(_ track: TrackRecord) -> Int64 {
        Int64(track.discNumber ?? 0) * 100_000 + Int64(track.trackNumber ?? 0)
    }

    /// The maximum number of `filePath` values bound into a single `IN (…)` clause.
    /// SQLite caps bound variables (`SQLITE_MAX_VARIABLE_NUMBER`, 999 on the oldest
    /// supported engines); 500 leaves ample headroom for the profile, visibility and
    /// cursor parameters the same statement binds.
    static let pathChunkSize = 500

    static func fetchTrackCountByPaths(
        _ db: Database,
        profileId: Int64,
        paths: [String]
    ) throws -> Int {
        let uniquePaths = Array(Set(paths))
        guard !uniquePaths.isEmpty else { return 0 }
        let visibility = try LibraryVisibility.predicate(db, profileId: profileId, column: "track.filePath")
        var count = 0
        for start in stride(from: 0, to: uniquePaths.count, by: pathChunkSize) {
            let chunk = Array(uniquePaths[start ..< min(start + pathChunkSize, uniquePaths.count)])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            var arguments: [any DatabaseValueConvertible] = chunk
            arguments.append(Availability.present.rawValue)
            arguments.append(contentsOf: visibility.arguments)
            count += try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM track
            WHERE track.filePath IN (\(placeholders))
              AND track.availability = ?
              AND \(visibility.sql)
            """, arguments: StatementArguments(arguments)) ?? 0
        }
        return count
    }

    static func fetchTracksByPaths(
        _ db: Database,
        profileId: Int64,
        paths: [String],
        after cursor: PageCursor<String>?,
        limit: Int
    ) throws -> [ProfileScopedTrack] {
        guard !paths.isEmpty else { return [] }
        let pageLimit = max(1, limit)
        let visibility = try LibraryVisibility.predicate(db, profileId: profileId, column: "track.filePath")
        var page: [ProfileScopedTrack] = []
        for start in stride(from: 0, to: paths.count, by: pathChunkSize) {
            let chunk = Array(paths[start ..< min(start + pathChunkSize, paths.count)])
            let sql = pathsChunkSQL(visibilitySQL: visibility.sql, pathCount: chunk.count, hasCursor: cursor != nil)
            var arguments: [any DatabaseValueConvertible] = [profileId]
            arguments.append(contentsOf: chunk)
            arguments.append(Availability.present.rawValue)
            arguments.append(contentsOf: visibility.arguments)
            if let cursor {
                arguments.append(cursor.key)
                arguments.append(cursor.id)
            }
            arguments.append(pageLimit)
            let chunkPage = try ProfileScopedTrack.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
            page = mergeByKeysetOrder(page, chunkPage, limit: pageLimit)
        }
        return page
    }

    /// The per-chunk profile-scoped keyset SELECT: the visible tracks whose
    /// `filePath` is one of `pathCount` bound values, each resolved against
    /// `profileTrackState`, ordered by the library's `(sortTitle, id)` keyset and
    /// `LIMIT`-capped. `hasCursor` adds the `(sortTitle, id) > (?, ?)` seek predicate.
    static func pathsChunkSQL(visibilitySQL: String, pathCount: Int, hasCursor: Bool) -> String {
        let placeholders = Array(repeating: "?", count: pathCount).joined(separator: ", ")
        var sql = """
        SELECT track.*, \(ProfileScopedTrack.resolvedColumnsSQL)
        FROM track
        \(ProfileScopedTrack.profileStateLeftJoinSQL)
        WHERE track.filePath IN (\(placeholders))
          AND track.availability = ?
          AND \(visibilitySQL)
        """
        if hasCursor {
            sql += "\n  AND (COALESCE(track.sortTitle, ''), track.id) > (?, ?)"
        }
        sql += "\nORDER BY COALESCE(track.sortTitle, ''), track.id\nLIMIT ?"
        return sql
    }

    /// Merges two `(sortTitle, id)`-sorted profile-scoped pages into the globally
    /// first `limit` rows. Each argument is one chunk's keyset page — already a
    /// prefix of that chunk's rows in `(sortTitle, id)` order — so the merge of the
    /// two, truncated to `limit`, is exactly the prefix of their union. Merging
    /// incrementally (never accumulating every chunk) keeps the working set bounded
    /// to `2 · limit` rows regardless of how many paths chunk.
    static func mergeByKeysetOrder(
        _ lhs: [ProfileScopedTrack],
        _ rhs: [ProfileScopedTrack],
        limit: Int
    ) -> [ProfileScopedTrack] {
        var merged: [ProfileScopedTrack] = []
        merged.reserveCapacity(min(limit, lhs.count + rhs.count))
        var leftIndex = 0
        var rightIndex = 0
        while leftIndex < lhs.count, rightIndex < rhs.count, merged.count < limit {
            if keysetOrders(lhs[leftIndex], before: rhs[rightIndex]) {
                merged.append(lhs[leftIndex])
                leftIndex += 1
            } else {
                merged.append(rhs[rightIndex])
                rightIndex += 1
            }
        }
        while leftIndex < lhs.count, merged.count < limit {
            merged.append(lhs[leftIndex])
            leftIndex += 1
        }
        while rightIndex < rhs.count, merged.count < limit {
            merged.append(rhs[rightIndex])
            rightIndex += 1
        }
        return merged
    }

    /// Whether `lhs` precedes `rhs` in the library's `(sortTitle, id)` order.
    /// `sortTitle` is compared by UTF-8 bytes to match SQLite's default `BINARY`
    /// collation — the same order the chunk queries' `ORDER BY COALESCE(sortTitle,
    /// '')` produces — so the in-memory merge and the per-chunk SQL never disagree.
    static func keysetOrders(_ lhs: ProfileScopedTrack, before rhs: ProfileScopedTrack) -> Bool {
        let lhsKey = lhs.track.sortTitle ?? ""
        let rhsKey = rhs.track.sortTitle ?? ""
        if lhsKey != rhsKey {
            return lhsKey.utf8.lexicographicallyPrecedes(rhsKey.utf8)
        }
        return (lhs.track.id ?? 0) < (rhs.track.id ?? 0)
    }
}
