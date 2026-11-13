import GRDB

/// The aggregate, full-text and set-membership reads that back the library's
/// genre picker, folder summaries and search — all **profile-scoped** through
/// ``LibraryVisibility`` where they span the whole library.
///
/// Extracted from `TrackRepository.swift` alongside `TrackRepository+Browse.swift`
/// to keep each file within the SwiftLint budgets.
public extension TrackRepository {
    /// A bounded availability tally for the tracks beneath one library-root folder.
    /// Not visibility-filtered: the folder is one of the profile's own roots.
    func rootSummary(rootPath: String) throws -> RootTrackSummary {
        try dbWriter.read { db in try Self.fetchRootSummary(db, rootPath: rootPath) }
    }

    /// The distinct genres visible to `profileId`.
    func distinctGenres() async throws -> LibraryGenreFacets {
        try await distinctGenres(profileId: ProfileRecord.guestID)
    }

    /// The distinct genres among the tracks visible to `profileId`.
    func distinctGenres(profileId: Int64) async throws -> LibraryGenreFacets {
        try await dbWriter.read { db in try Self.fetchGenreFacets(db, profileId: profileId) }
    }

    /// The distinct genres beneath a library-root folder (already profile-owned).
    func distinctGenres(rootPath: String) async throws -> LibraryGenreFacets {
        try await dbWriter.read { db in try Self.fetchGenreFacets(db, rootPath: rootPath) }
    }

    /// The distinct genres within a playlist's membership.
    func distinctGenres(playlistId: Int64) async throws -> LibraryGenreFacets {
        try await dbWriter.read { db in try Self.fetchGenreFacets(db, playlistId: playlistId) }
    }

    /// Full-text search over the visible tracks, ranked by relevance.
    ///
    /// `matchingAllPrefixesIn` turns "boh rha" into the FTS5 pattern `boh* rha*`,
    /// so each whitespace-separated term prefix-matches a token. Candidate rows are
    /// joined back through the external-content rowid, filtered to the profile's
    /// visible tracks, and ordered by the FTS5 `rank` (bm25) column.
    func searchTracks(
        profileId: Int64 = ProfileRecord.guestID,
        query: String,
        limit: Int = 50
    ) throws -> [TrackRecord] {
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: query) else { return [] }
        let pageLimit = max(1, limit)
        return try dbWriter.read { db in
            let visibility = try LibraryVisibility.predicate(db, profileId: profileId, column: "track.filePath")
            var arguments: [any DatabaseValueConvertible] = [pattern.rawPattern]
            arguments.append(contentsOf: visibility.arguments)
            arguments.append(pageLimit)
            return try TrackRecord.fetchAll(db, sql: """
            SELECT track.* FROM track
            JOIN trackSearch ON trackSearch.rowid = track.id
            WHERE trackSearch MATCH ? AND \(visibility.sql)
              AND \(CueSuppression.notSuppressedSQL(qualifier: "track"))
            ORDER BY trackSearch.rank
            LIMIT ?
            """, arguments: StatementArguments(arguments))
        }
    }

    /// The set of track ids this profile has favourited — the per-row favourite
    /// indicator for the library/album/playlist lists, resolved from
    /// `profileTrackState` instead of the frozen `track.isFavourite` column.
    ///
    /// Bounded: favourites are a small, user-curated subset, and the
    /// `(profileId, isFavourite, customPosition)` covering index selects them
    /// without scanning the `track` table.
    func favouriteTrackIDs(
        profileId: Int64 = ProfileRecord.guestID,
        limit: Int = 100_000
    ) throws -> Set<Int64> {
        try dbWriter.read { db in
            let ids = try Int64.fetchAll(db, sql: """
            SELECT trackId FROM profileTrackState
            WHERE profileId = ? AND isFavourite = 1
            LIMIT ?
            """, arguments: [profileId, max(1, limit)])
            return Set(ids)
        }
    }

    /// Every track visible to `profileId` beneath `rootPath`, for folder export.
    ///
    /// Unbounded by design (an export writes every row), but visibility-scoped so a
    /// folder export never leaks a track the profile cannot otherwise see.
    func visibleTracksUnderRoot(
        profileId: Int64 = ProfileRecord.guestID,
        rootPath: String
    ) throws -> [TrackRecord] {
        try dbWriter.read { db in
            let visibility = try LibraryVisibility.predicate(db, profileId: profileId)
            return try TrackRecord
                .filter(sql: "filePath LIKE ? ESCAPE '\\'", arguments: [Self.likePrefixPattern(forRoot: rootPath)])
                .filter(sql: visibility.sql, arguments: StatementArguments(visibility.arguments))
                .fetchAll(db)
        }
    }
}

private extension TrackRepository {
    static func fetchRootSummary(_ db: Database, rootPath: String) throws -> RootTrackSummary {
        let sql = """
        SELECT
          COUNT(*) AS total,
          COALESCE(SUM(availability = ?), 0) AS present,
          COALESCE(SUM(availability = ?), 0) AS missing,
          COALESCE(SUM(availability = ?), 0) AS externalOffline,
          MAX(dateAdded) AS newestDateAdded
        FROM \(TrackRecord.databaseTableName)
        WHERE filePath LIKE ? ESCAPE '\\'
        """
        let arguments: StatementArguments = [
            Availability.present.rawValue,
            Availability.missing.rawValue,
            Availability.externalOffline.rawValue,
            likePrefixPattern(forRoot: rootPath),
        ]
        guard let row = try Row.fetchOne(db, sql: sql, arguments: arguments) else {
            return RootTrackSummary(total: 0, present: 0, missing: 0, externalOffline: 0)
        }
        let total: Int = row["total"]
        let present: Int = row["present"]
        let missing: Int = row["missing"]
        let externalOffline: Int = row["externalOffline"]
        let newestDateAdded: Double? = row["newestDateAdded"]
        return RootTrackSummary(
            total: total,
            present: present,
            missing: missing,
            externalOffline: externalOffline,
            newestDateAdded: newestDateAdded
        )
    }

    static func fetchGenreFacets(
        _ db: Database,
        profileId: Int64? = nil,
        rootPath: String? = nil,
        playlistId: Int64? = nil
    ) throws -> LibraryGenreFacets {
        let table = TrackRecord.databaseTableName
        var whereClause = ""
        var args: [any DatabaseValueConvertible] = []
        if let rootPath {
            let pattern = rootPath.hasSuffix("/") ? rootPath + "%" : rootPath + "/%"
            whereClause = " AND filePath LIKE ? ESCAPE '\\'"
            args.append(pattern)
        } else if let playlistId {
            whereClause = " AND id IN (SELECT trackId FROM playlistTrack WHERE playlistId = ?)"
            args.append(playlistId)
        } else if let profileId {
            let visibility = try LibraryVisibility.predicate(db, profileId: profileId)
            whereClause = " AND \(visibility.sql)"
            args.append(contentsOf: visibility.arguments)
        }
        let genres = try String.fetchAll(db, sql: """
        SELECT DISTINCT genre FROM \(table)
        WHERE genre IS NOT NULL AND genre <> ''\(whereClause)
        ORDER BY genre COLLATE NOCASE
        """, arguments: StatementArguments(args))
        let untagged = try Int.fetchOne(db, sql: """
        SELECT COUNT(*) FROM \(table) WHERE (genre IS NULL OR genre = '')\(whereClause)
        """, arguments: StatementArguments(args)) ?? 0
        return LibraryGenreFacets(genres: genres, includesUntagged: untagged > 0)
    }
}
