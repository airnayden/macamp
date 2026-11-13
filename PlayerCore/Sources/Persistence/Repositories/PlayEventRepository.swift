import Foundation
import GRDB

/// One track's whole listening history, collapsed to a single aggregate row.
///
/// Lifetime, never windowed: this is the "you have played this 47 times" panel
/// figure, so it counts every raw event still inside the 24-month horizon. A track
/// with no events at all has no ``TrackPlayStats`` — the absence is the state, which
/// is why the read returns an optional rather than an all-zero value.
public struct TrackPlayStats: Sendable, Equatable {
    /// How many times the track was played.
    public var plays: Int
    /// How many of those plays the listener cut short.
    public var skips: Int
    /// Total seconds actually heard across every play.
    public var secondsListened: Double
    /// When the earliest surviving play began, as seconds since the Unix epoch.
    public var firstPlayedAt: TimeInterval
    /// When the most recent play began, as seconds since the Unix epoch.
    public var lastPlayedAt: TimeInterval

    public init(
        plays: Int,
        skips: Int,
        secondsListened: Double,
        firstPlayedAt: TimeInterval,
        lastPlayedAt: TimeInterval
    ) {
        self.plays = plays
        self.skips = skips
        self.secondsListened = secondsListened
        self.firstPlayedAt = firstPlayedAt
        self.lastPlayedAt = lastPlayedAt
    }
}

/// A most-played track, carrying the backlink AND the capture-time snapshot that
/// identifies it.
///
/// The three text fields are the **denormalised `playEvent` columns**, NOT live
/// tags. They exist so a caller can key a row by the same identity basis the
/// listening digest uses and still match after the file has been retagged — the
/// history remembers what the track was called when it was played.
public struct TopTrackId: Sendable, Equatable {
    /// Best-effort backlink to the library row. Never a foreign key.
    public var trackId: Int64
    /// Artist as known when these plays were captured.
    public var artistName: String?
    /// Title as known when these plays were captured.
    public var title: String?
    /// Album as known when these plays were captured.
    public var albumTitle: String?
    /// How many plays this `(trackId, artist, title, album)` snapshot accumulated.
    public var plays: Int

    public init(
        trackId: Int64,
        artistName: String?,
        title: String?,
        albumTitle: String?,
        plays: Int
    ) {
        self.trackId = trackId
        self.artistName = artistName
        self.title = title
        self.albumTitle = albumTitle
        self.plays = plays
    }
}

/// Off-actor, windowed access to the v15 listening-history tables.
///
/// Every read is keyset-paginated and `LIMIT`-capped, and every delete is
/// batch-bounded, so a profile with years of history never materialises more than
/// one page at a time (the library-memory invariant applies to statistics too).
public protocol PlayEventRepositoryProviding: Sendable {
    /// Appends one play event, returning its assigned rowid.
    @discardableResult
    func insertPlayEvent(_ event: PlayEventRecord) async throws -> Int64

    /// One page of a profile's events, newest first.
    ///
    /// - Parameter cursor: The `(startedAt, id)` anchor of the previous page's last
    ///   row; `nil` starts at the newest event.
    func playEvents(
        profileId: Int64,
        before cursor: PageCursor<Double>?,
        limit: Int
    ) async throws -> Page<PlayEventRecord, Double>

    /// One page of a profile's monthly rollups, oldest month first.
    func rollups(
        profileId: Int64,
        after cursor: PageCursor<String>?,
        limit: Int
    ) async throws -> Page<PlayEventRollupRecord, String>

    /// Deletes at most `limit` of the profile's events started before `cutoff`,
    /// returning how many were removed. Call repeatedly until it returns `0`.
    @discardableResult
    func deleteEventsOlderThan(
        _ cutoff: TimeInterval,
        profileId: Int64,
        limit: Int
    ) async throws -> Int

    /// Writes `rollup` as the ABSOLUTE state of its
    /// `(profileId, yearMonth, artistKey, genreKey)` bucket.
    func upsertRollup(_ rollup: PlayEventRollupRecord) async throws

    /// One track's lifetime history as a single aggregate, or `nil` when the profile
    /// has never played it.
    func trackPlayStats(profileId: Int64, trackId: Int64) async throws -> TrackPlayStats?

    /// The profile's most-played tracks whose plays began at or after `since`,
    /// ranked by play count.
    ///
    /// - Parameters:
    ///   - since: Inclusive lower bound on `startedAt`. Pass `0` for the whole
    ///     surviving raw horizon.
    ///   - limit: Row ceiling, capped at ``PlayEventRepository/fetchLimit``. Rows are
    ///     grouped more finely than the listening digest groups its identities, so
    ///     callers that align the two pass a doubled limit — see the implementation.
    func topTrackIds(profileId: Int64, since: TimeInterval, limit: Int) async throws -> [TopTrackId]
}

/// The concrete ``PlayEventRepositoryProviding`` over a GRDB writer.
///
/// Uses GRDB's async reader/writer overloads throughout so a main-actor caller
/// never blocks on a database connection.
public struct PlayEventRepository: PlayEventRepositoryProviding {
    /// The hard ceiling on any single page, applied even when a caller asks for more.
    public static let fetchLimit = 500
    /// The hard ceiling on one pruning batch.
    public static let deleteBatchLimit = 5000

    private let dbWriter: any DatabaseWriter

    public init(_ appDatabase: AppDatabase) {
        dbWriter = appDatabase.writer
    }

    public init(_ dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    @discardableResult
    public func insertPlayEvent(_ event: PlayEventRecord) async throws -> Int64 {
        try await dbWriter.write { db in
            var record = event
            try record.insert(db)
            return record.id ?? 0
        }
    }

    public func playEvents(
        profileId: Int64,
        before cursor: PageCursor<Double>? = nil,
        limit: Int = PlayEventRepository.fetchLimit
    ) async throws -> Page<PlayEventRecord, Double> {
        let capped = min(max(1, limit), Self.fetchLimit)
        return try await dbWriter.read { db in
            try PlayEventRecord
                .filter(PlayEventRecord.Columns.profileId == profileId)
                .fetchPage(
                    db,
                    sort: KeysetSort(keyExpressionSQL: "\"startedAt\"", direction: .descending),
                    after: cursor,
                    limit: capped,
                    cursorForLast: { PageCursor(key: $0.startedAt, id: $0.id ?? 0) }
                )
        }
    }

    public func rollups(
        profileId: Int64,
        after cursor: PageCursor<String>? = nil,
        limit: Int = PlayEventRepository.fetchLimit
    ) async throws -> Page<PlayEventRollupRecord, String> {
        let capped = min(max(1, limit), Self.fetchLimit)
        return try await dbWriter.read { db in
            try PlayEventRollupRecord
                .filter(PlayEventRollupRecord.Columns.profileId == profileId)
                .fetchPage(
                    db,
                    sort: KeysetSort(keyExpressionSQL: "\"yearMonth\""),
                    after: cursor,
                    limit: capped,
                    cursorForLast: { PageCursor(key: $0.yearMonth, id: $0.id ?? 0) }
                )
        }
    }

    @discardableResult
    public func deleteEventsOlderThan(
        _ cutoff: TimeInterval,
        profileId: Int64,
        limit: Int = PlayEventRepository.deleteBatchLimit
    ) async throws -> Int {
        let capped = min(max(1, limit), Self.deleteBatchLimit)
        return try await dbWriter.write { db in
            let victims = try PlayEventRecord
                .select(PlayEventRecord.Columns.id, as: Int64.self)
                .filter(PlayEventRecord.Columns.profileId == profileId)
                .filter(PlayEventRecord.Columns.startedAt < cutoff)
                .order(PlayEventRecord.Columns.startedAt.asc, PlayEventRecord.Columns.id.asc)
                .limit(capped)
                .fetchAll(db)
            guard !victims.isEmpty else { return 0 }
            return try PlayEventRecord.filter(keys: victims).deleteAll(db)
        }
    }

    /// Replaces the bucket's counters outright rather than adding to them, which is
    /// what makes a re-run of the compactor idempotent. The row is located by its
    /// unique key and its rowid carried over, so no SQLite upsert-target support is
    /// assumed.
    public func upsertRollup(_ rollup: PlayEventRollupRecord) async throws {
        try await dbWriter.write { db in
            var record = rollup
            record.id = try Self.existingRollupID(db, matching: rollup)
            try record.save(db)
        }
    }

    /// Served by `playEvent_on_profileId_trackId`
    /// (`AppDatabase+Migrations+Stats.swift:48-52`), so the scan stays bounded to this
    /// one track's events however deep the profile's history runs. One `read`, one
    /// aggregate, no row materialisation.
    public func trackPlayStats(profileId: Int64, trackId: Int64) async throws -> TrackPlayStats? {
        try await dbWriter.read { db in
            let sql = """
            SELECT
              COUNT(*) AS plays,
              SUM(CASE WHEN skipped THEN 1 ELSE 0 END) AS skips,
              SUM(secondsListened) AS secondsListened,
              MIN(startedAt) AS firstPlayedAt,
              MAX(startedAt) AS lastPlayedAt
            FROM \(PlayEventRecord.databaseTableName)
            WHERE profileId = ? AND trackId = ?
            """
            guard let row = try Row.fetchOne(db, sql: sql, arguments: [profileId, trackId]) else {
                return nil
            }
            // A bare aggregate over an empty set still returns one row — of NULLs — so
            // "never played" surfaces as a zero count, not a missing row. This guard has
            // to come before every other column is read, because the four aggregates
            // below are NULL in exactly that case.
            let plays: Int = row["plays"]
            guard plays > 0 else { return nil }
            return TrackPlayStats(
                plays: plays,
                skips: row["skips"],
                secondsListened: row["secondsListened"],
                firstPlayedAt: row["firstPlayedAt"],
                lastPlayedAt: row["lastPlayedAt"]
            )
        }
    }

    /// HONESTY NOTE: this grouping is strictly FINER than the digest's — case-sensitive
    /// BINARY collation and split per trackId, versus the digest's case-folded,
    /// trackId-agnostic `identityKey` — so callers pass a DOUBLED limit
    /// (`topEntityLimit * 2` = 50, still bounded) and the surplus absorbs case-variant
    /// /duplicate-import splits so a displayed top-10 identity cannot fall out of range.
    ///
    /// Cost honesty: the `(profileId, startedAt)` index bounds windowed calls;
    /// `since: 0` scans the profile's full raw horizon and the GROUP BY builds a temp
    /// b-tree — acceptable because the digest already scans the same rows in the same
    /// load. NO migration, NO new index.
    ///
    /// `ORDER BY plays DESC, trackId ASC` is a total order, so equal play counts rank
    /// the same way on every run.
    public func topTrackIds(
        profileId: Int64,
        since: TimeInterval,
        limit: Int = PlayEventRepository.fetchLimit
    ) async throws -> [TopTrackId] {
        let capped = min(max(1, limit), Self.fetchLimit)
        return try await dbWriter.read { db in
            let sql = """
            SELECT trackId, artistName, title, albumTitle, COUNT(*) AS plays
            FROM \(PlayEventRecord.databaseTableName)
            WHERE profileId = ? AND trackId IS NOT NULL AND startedAt >= ?
            GROUP BY trackId, artistName, title, albumTitle
            ORDER BY plays DESC, trackId ASC
            LIMIT ?
            """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [profileId, since, capped])
            return rows.map { row in
                TopTrackId(
                    trackId: row["trackId"],
                    artistName: row["artistName"],
                    title: row["title"],
                    albumTitle: row["albumTitle"],
                    plays: row["plays"]
                )
            }
        }
    }

    private static func existingRollupID(
        _ db: Database,
        matching rollup: PlayEventRollupRecord
    ) throws -> Int64? {
        try PlayEventRollupRecord
            .select(PlayEventRollupRecord.Columns.id, as: Int64.self)
            .filter(PlayEventRollupRecord.Columns.profileId == rollup.profileId)
            .filter(PlayEventRollupRecord.Columns.yearMonth == rollup.yearMonth)
            .filter(PlayEventRollupRecord.Columns.artistKey == rollup.artistKey)
            .filter(PlayEventRollupRecord.Columns.genreKey == rollup.genreKey)
            .fetchOne(db)
    }
}
