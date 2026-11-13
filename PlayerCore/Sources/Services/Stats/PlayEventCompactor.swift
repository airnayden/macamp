// PlayEventCompactor — folds aged raw play events into permanent monthly rollups.
//
// Raw `playEvent` rows are the high-resolution record: every play, with its own
// timestamp, local UTC offset, source surface and completion fraction. Keeping them
// forever is unbounded, so past a rolling horizon each month collapses into
// `playEventRollup` rows keyed `(profileId, yearMonth, artistKey, genreKey)` —
// permanent, tiny, and enough to preserve long-term taste.
//
// Four rules are load-bearing:
//
//  1. **One month implementation.** Every `yearMonth` key and every horizon
//     comparison goes through ``CivilMonth`` — no `Calendar`, no `TimeZone`, no
//     `strftime` in SQL. The digest (which unions raw events with rollups) must
//     bucket months with the SAME code or the union double-counts at a boundary.
//  2. **The horizon boundary month is EXCLUSIVE.** An event is compacted only when
//     its civil month precedes `now()`'s by MORE than 24 whole months, so the month
//     exactly 24 back stays raw. See ``horizonMonthIndex(now:)``.
//  3. **A pass is ONE transaction.** Aggregation, rollup merges and raw deletions
//     all run inside a single `dbWriter.write`. A failure anywhere rolls the whole
//     pass back, so a month's source rows are never deleted without their rollup
//     (which would silently lose history) and never counted twice (which a
//     rollup-without-deletion would cause on the next pass).
//  4. **`playSegmentHeat` is never touched.** It is an aggregate, not a log: it has
//     no timestamps to age and is deliberately excluded from every statement here.
//
// Because compaction deletes exactly what it aggregated, re-running it is a no-op:
// the second pass finds nothing left below the horizon. Rows that appear in an
// already-rolled month LATER (an archive import, a backdated write) are genuinely
// new data — the next pass folds them into the EXISTING rollup row through the
// unique key, summing rather than replacing.
import Foundation
import GRDB
import Persistence

/// What one compaction pass did. Returned for logging and tests; nothing branches
/// on it in production.
public struct PlayEventCompactionResult: Sendable, Equatable, Hashable {
    /// How many `(profile, month)` windows were rolled up.
    public var monthsCompacted: Int
    /// How many raw `playEvent` rows were aggregated and then deleted.
    public var eventsCompacted: Int
    /// How many rollup rows were written (inserted or summed into).
    public var rollupsWritten: Int
    /// The first month kept RAW, as `"YYYY-MM"`. Everything strictly before it is
    /// rolled up; this month and later stay raw.
    public var horizonYearMonth: String

    public init(
        monthsCompacted: Int = 0,
        eventsCompacted: Int = 0,
        rollupsWritten: Int = 0,
        horizonYearMonth: String = ""
    ) {
        self.monthsCompacted = monthsCompacted
        self.eventsCompacted = eventsCompacted
        self.rollupsWritten = rollupsWritten
        self.horizonYearMonth = horizonYearMonth
    }
}

/// Ages raw listening history into permanent monthly rollups.
public protocol PlayEventCompacting: Sendable {
    /// Runs one idempotent, atomic compaction pass over every profile.
    @discardableResult
    func compact() async throws -> PlayEventCompactionResult
}

/// The production ``PlayEventCompacting`` over the v15 statistics tables.
public struct PlayEventCompactor: PlayEventCompacting {
    /// How many whole months of raw events are kept before a month is rolled up.
    public static let horizonMonths = 24

    /// The share of a track that counts as having heard it through.
    ///
    /// A natural end rarely reports a completion fraction of exactly `1` (the
    /// playhead is sampled at the transition, and gapless hands over slightly
    /// early), so an equality test would undercount almost every completed play.
    /// The digest must classify raw events with this SAME constant or a track's
    /// completion rate would step when its month crosses the horizon.
    public static let completionThreshold = 0.9

    private let dbWriter: any DatabaseWriter
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - appDatabase: The migrated application database.
    ///   - now: The clock the horizon is measured from. Injected so tests can place
    ///     "now" anywhere without waiting for real time to pass.
    public init(_ appDatabase: AppDatabase, now: @escaping @Sendable () -> Date = { Date() }) {
        self.init(appDatabase.writer, now: now)
    }

    public init(_ dbWriter: any DatabaseWriter, now: @escaping @Sendable () -> Date = { Date() }) {
        self.dbWriter = dbWriter
        self.now = now
    }

    /// The ``CivilMonth`` index of the first month kept RAW.
    ///
    /// The horizon is defined on civil months, not on elapsed seconds: an event is
    /// compacted iff its month precedes `now`'s by MORE than ``horizonMonths``
    /// whole months. Subtracting the horizon from `now`'s index therefore yields the
    /// oldest month that STAYS raw — the boundary month is exclusive.
    public static func horizonMonthIndex(now: Date) -> Int {
        CivilMonth.monthIndex(fromEpochSeconds: now.timeIntervalSince1970) - horizonMonths
    }

    @discardableResult
    public func compact() async throws -> PlayEventCompactionResult {
        let horizonIndex = Self.horizonMonthIndex(now: now())
        let horizonStart = CivilMonth.startOfMonthEpochSeconds(atIndex: horizonIndex)
        let horizonKey = CivilMonth.yearMonthKey(atIndex: horizonIndex)
        // ONE transaction for the whole pass: see rule 3 in the file header.
        return try await dbWriter.write { db in
            var result = PlayEventCompactionResult(horizonYearMonth: horizonKey)
            for profileId in try Self.profilesWithAgedEvents(db, before: horizonStart) {
                try Self.compactProfile(db, profileId: profileId, before: horizonStart, into: &result)
            }
            return result
        }
    }
}

// MARK: - One aggregated bucket

/// One `GROUP BY (artistKey, genreKey)` row of a single profile-month.
///
/// `listenedMicroseconds` is an INTEGER sum of microsecond-quantized durations, not
/// a `SUM` of doubles: floating-point addition is not associative, so a double sum
/// could differ between two runs that visit the same rows in a different order (and
/// SQLite is free to change that order). Quantizing first makes the total a
/// function of the SET of events, never of their order.
private struct CompactionBucket: FetchableRecord, Decodable {
    var artistKey: String
    var genreKey: String
    var plays: Int
    var listenedMicroseconds: Int64
    var skips: Int
    var completions: Int
}

// MARK: - The pass

private extension PlayEventCompactor {
    /// The profiles that own at least one aged event.
    ///
    /// Read from `playEvent` rather than `profile` so the pass never depends on the
    /// profile table's contents, and covered by `playEvent_on_profileId_startedAt`.
    static func profilesWithAgedEvents(_ db: Database, before horizonStart: Double) throws -> [Int64] {
        try Int64.fetchAll(
            db,
            sql: """
            SELECT DISTINCT profileId FROM playEvent
            WHERE startedAt < ?
            ORDER BY profileId
            """,
            arguments: [horizonStart]
        )
    }

    /// Rolls up one profile's aged months, oldest first.
    ///
    /// Each iteration seeks the profile's oldest remaining aged event (an index
    /// range scan, not a table scan), rolls up the whole civil month containing it,
    /// and deletes that month's rows — so the next `MIN` lands on the next month
    /// that actually has data. Months with no events cost nothing.
    static func compactProfile(
        _ db: Database,
        profileId: Int64,
        before horizonStart: Double,
        into result: inout PlayEventCompactionResult
    ) throws {
        while let earliest = try oldestAgedEvent(db, profileId: profileId, before: horizonStart) {
            let index = CivilMonth.monthIndex(fromEpochSeconds: earliest)
            let start = CivilMonth.startOfMonthEpochSeconds(atIndex: index)
            let end = CivilMonth.startOfMonthEpochSeconds(atIndex: index + 1)
            let buckets = try aggregate(db, profileId: profileId, from: start, to: end)
            // Unreachable — `earliest` lies inside `[start, end)`, so the same
            // predicate must group at least one row. Guards the loop regardless: a
            // zero-bucket month would otherwise never delete and never terminate.
            guard !buckets.isEmpty else { break }
            let yearMonth = CivilMonth.yearMonthKey(atIndex: index)
            for bucket in buckets {
                try merge(db, bucket: bucket, profileId: profileId, yearMonth: yearMonth)
            }
            try deleteEvents(db, profileId: profileId, from: start, to: end)
            result.monthsCompacted += 1
            result.rollupsWritten += buckets.count
            result.eventsCompacted += buckets.reduce(0) { $0 + $1.plays }
        }
    }

    static func oldestAgedEvent(_ db: Database, profileId: Int64, before horizonStart: Double) throws -> Double? {
        try Double.fetchOne(
            db,
            sql: "SELECT MIN(startedAt) FROM playEvent WHERE profileId = ? AND startedAt < ?",
            arguments: [profileId, horizonStart]
        )
    }

    /// Aggregates one profile-month in SQL, so no page of raw rows is ever
    /// materialised in memory (the bounded-memory invariant applies to statistics
    /// too — a month of a heavy listener is thousands of rows).
    ///
    /// `COALESCE(…, '')` is the rollup's unknown-key sentinel: SQL treats
    /// `NULL != NULL`, so NULL artists would each land in their own `GROUP BY`
    /// bucket and defeat the unique key the merge upserts against.
    static func aggregate(
        _ db: Database,
        profileId: Int64,
        from start: Double,
        to end: Double
    ) throws -> [CompactionBucket] {
        try CompactionBucket.fetchAll(
            db,
            sql: """
            SELECT COALESCE(artistName, ?) AS artistKey,
                   COALESCE(genre, ?) AS genreKey,
                   COUNT(*) AS plays,
                   SUM(CAST(ROUND(secondsListened * ?) AS INTEGER)) AS listenedMicroseconds,
                   SUM(skipped) AS skips,
                   SUM(CASE WHEN completionFraction >= ? THEN 1 ELSE 0 END) AS completions
            FROM playEvent
            WHERE profileId = ? AND startedAt >= ? AND startedAt < ?
            GROUP BY artistKey, genreKey
            ORDER BY artistKey, genreKey
            """,
            arguments: [
                PlayEventRollupRecord.unknownKey,
                PlayEventRollupRecord.unknownKey,
                StatsSeconds.microsecondsPerSecond,
                PlayEventCompactor.completionThreshold,
                profileId,
                start,
                end,
            ]
        )
    }

    /// Adds `bucket` to its rollup row, creating the row when the month is new.
    ///
    /// Deliberately additive rather than replacing: a month can be compacted more
    /// than once (backdated events, an archive import), and each pass carries only
    /// the events it is about to delete. Summing is what makes the second pass fold
    /// into the first's row instead of overwriting it.
    static func merge(
        _ db: Database,
        bucket: CompactionBucket,
        profileId: Int64,
        yearMonth: String
    ) throws {
        var record = try existingRollup(db, profileId: profileId, yearMonth: yearMonth, bucket: bucket)
            ?? PlayEventRollupRecord(
                profileId: profileId,
                yearMonth: yearMonth,
                artistKey: bucket.artistKey,
                genreKey: bucket.genreKey
            )
        record.plays += bucket.plays
        record.skips += bucket.skips
        record.completions += bucket.completions
        let carried = StatsSeconds.microseconds(fromSeconds: record.listenedSeconds)
        record.listenedSeconds = StatsSeconds.seconds(fromMicroseconds: carried + bucket.listenedMicroseconds)
        try record.save(db)
    }

    static func existingRollup(
        _ db: Database,
        profileId: Int64,
        yearMonth: String,
        bucket: CompactionBucket
    ) throws -> PlayEventRollupRecord? {
        try PlayEventRollupRecord
            .filter(PlayEventRollupRecord.Columns.profileId == profileId)
            .filter(PlayEventRollupRecord.Columns.yearMonth == yearMonth)
            .filter(PlayEventRollupRecord.Columns.artistKey == bucket.artistKey)
            .filter(PlayEventRollupRecord.Columns.genreKey == bucket.genreKey)
            .fetchOne(db)
    }

    /// Deletes exactly the rows ``aggregate(_:profileId:from:to:)`` just summed —
    /// same predicate, same transaction, so no row can be counted twice or lost.
    static func deleteEvents(_ db: Database, profileId: Int64, from start: Double, to end: Double) throws {
        try db.execute(
            sql: "DELETE FROM playEvent WHERE profileId = ? AND startedAt >= ? AND startedAt < ?",
            arguments: [profileId, start, end]
        )
    }
}
