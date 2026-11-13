// PlayEventCompactorTests — what a compaction pass rolls up, deletes, and refuses.
//
// `now` is pinned with `FakeClock` to 2026-07-25T00:00:00Z throughout, which puts
// the 24-month horizon at **2024-07**: everything before 2024-07-01T00:00:00Z is
// compacted, that month and later stay raw. Every timestamp below is a hand-computed
// UTC instant so the horizon assertions never depend on the machine's calendar.
//
// Every database access sits in a NON-async helper: inside an `async` test,
// `writer.write { … }` resolves to GRDB's async overload and would need an `await`
// that reads like a mistake. Keeping the closures in sync helpers also keeps the
// `#expect(try …)` autoclosure trap out of the assertions — every fetched value is
// bound to a `let` first.
import Foundation
import GRDB
import Persistence
import PlayerCoreTestSupport
@testable import Services
import Testing

// MARK: - Fixture instants (UTC, hand-computed)

private enum Instant {
    /// 2026-07-25T00:00:00Z — the pinned "now".
    static let now: Double = 1_784_937_600
    /// 2024-07-01T00:00:00Z — the first second of the horizon month, which STAYS raw.
    static let horizonMonthStart: Double = 1_719_792_000
    /// 2024-06-30T23:59:59Z — the last second before the horizon, which IS compacted.
    static let lastAgedSecond: Double = 1_719_791_999
    /// 2024-05-15T00:00:00Z — a whole month further back.
    static let may2024: Double = 1_715_731_200
    /// 2026-07-20T00:00:00Z — recent history, far inside the horizon.
    static let recent: Double = 1_784_505_600
}

// MARK: - Fixture helpers

private func makeDatabase() throws -> AppDatabase {
    try AppDatabase.makeEmpty()
}

private func makeCompactor(_ database: AppDatabase, now: Double = Instant.now) -> PlayEventCompactor {
    PlayEventCompactor(database, now: FakeClock(epochSeconds: now).nowProvider)
}

@discardableResult
private func insertEvent(
    _ database: AppDatabase,
    profileId: Int64 = ProfileRecord.guestID,
    startedAt: Double,
    artist: String? = "Artist",
    genre: String? = "Genre",
    listened: Double = 100,
    completion: Double = 1,
    skipped: Bool = false
) throws -> Int64 {
    try database.writer.write { db -> Int64 in
        var record = PlayEventRecord(
            profileId: profileId,
            trackId: 1,
            artistName: artist,
            title: "Title",
            genre: genre,
            durationSeconds: 200,
            startedAt: startedAt,
            utcOffsetSeconds: 0,
            secondsListened: listened,
            completionFraction: completion,
            skipped: skipped
        )
        try record.insert(db)
        return record.id ?? 0
    }
}

private func rollups(_ database: AppDatabase) throws -> [PlayEventRollupRecord] {
    try database.writer.read { db in
        try PlayEventRollupRecord
            .order(
                PlayEventRollupRecord.Columns.yearMonth,
                PlayEventRollupRecord.Columns.artistKey,
                PlayEventRollupRecord.Columns.genreKey
            )
            .fetchAll(db)
    }
}

private func remainingEvents(_ database: AppDatabase) throws -> [PlayEventRecord] {
    try database.writer.read { db in
        try PlayEventRecord.order(PlayEventRecord.Columns.startedAt).fetchAll(db)
    }
}

private func makeSecondProfile(_ database: AppDatabase) throws -> Int64 {
    try database.writer.write { db -> Int64 in
        var record = ProfileRecord(name: "Second")
        try record.insert(db)
        return record.id ?? 0
    }
}

private func insertSegmentHeat(_ database: AppDatabase, counts: [UInt32]) throws -> PlaySegmentHeatRecord {
    let blob = try PlaySegmentHeatRecord.encodeBuckets(counts)
    return try database.writer.write { db -> PlaySegmentHeatRecord in
        var record = PlaySegmentHeatRecord(
            profileId: ProfileRecord.guestID,
            trackId: 1,
            artistName: "Artist",
            title: "Title",
            durationSeconds: 200,
            bucketCounts: blob,
            totalPasses: 4,
            updatedAt: Instant.may2024
        )
        try record.insert(db)
        return record
    }
}

private func segmentHeatRows(_ database: AppDatabase) throws -> [PlaySegmentHeatRecord] {
    try database.writer.read { db in try PlaySegmentHeatRecord.fetchAll(db) }
}

// MARK: - Horizon

@Suite("PlayEventCompactor — the 24-month horizon")
struct PlayEventCompactorHorizonTests {
    @Test("the boundary month is exclusive: its first second stays raw, the second before it is rolled")
    func boundaryMonthIsExclusive() async throws {
        let database = try makeDatabase()
        try insertEvent(database, startedAt: Instant.lastAgedSecond)
        try insertEvent(database, startedAt: Instant.horizonMonthStart)

        let result = try await makeCompactor(database).compact()

        #expect(result.horizonYearMonth == "2024-07")
        #expect(result.monthsCompacted == 1)
        #expect(result.eventsCompacted == 1)
        let rolled = try rollups(database)
        #expect(rolled.count == 1)
        #expect(rolled.first?.yearMonth == "2024-06")
        let kept = try remainingEvents(database)
        #expect(kept.count == 1)
        #expect(kept.first?.startedAt == Instant.horizonMonthStart)
    }

    @Test("only months past the horizon are compacted; newer months are untouched")
    func newerMonthsAreUntouched() async throws {
        let database = try makeDatabase()
        try insertEvent(database, startedAt: Instant.may2024)
        try insertEvent(database, startedAt: Instant.lastAgedSecond)
        try insertEvent(database, startedAt: Instant.horizonMonthStart)
        try insertEvent(database, startedAt: Instant.recent)

        let result = try await makeCompactor(database).compact()

        #expect(result.monthsCompacted == 2)
        #expect(result.eventsCompacted == 2)
        let months = try rollups(database).map(\.yearMonth)
        #expect(months == ["2024-05", "2024-06"])
        let kept = try remainingEvents(database).map(\.startedAt)
        #expect(kept == [Instant.horizonMonthStart, Instant.recent])
    }

    @Test("a database with nothing past the horizon is a complete no-op")
    func nothingToCompact() async throws {
        let database = try makeDatabase()
        try insertEvent(database, startedAt: Instant.recent)

        let result = try await makeCompactor(database).compact()

        #expect(result.monthsCompacted == 0)
        #expect(result.eventsCompacted == 0)
        let rolled = try rollups(database)
        #expect(rolled.isEmpty)
        let kept = try remainingEvents(database)
        #expect(kept.count == 1)
    }

    @Test("profiles are rolled up independently")
    func profilesAreIndependent() async throws {
        let database = try makeDatabase()
        let second = try makeSecondProfile(database)
        try insertEvent(database, startedAt: Instant.may2024)
        try insertEvent(database, profileId: second, startedAt: Instant.may2024)

        try await makeCompactor(database).compact()

        let rolled = try rollups(database)
        #expect(rolled.count == 2)
        #expect(Set(rolled.map(\.profileId)) == [ProfileRecord.guestID, second])
        #expect(rolled.allSatisfy { $0.plays == 1 })
    }
}

// MARK: - Aggregation

@Suite("PlayEventCompactor — aggregation")
struct PlayEventCompactorAggregationTests {
    @Test("plays, skips and completions are counted per artist/genre bucket")
    func bucketCounters() async throws {
        let database = try makeDatabase()
        try insertEvent(database, startedAt: Instant.may2024, completion: 1)
        try insertEvent(database, startedAt: Instant.may2024 + 60, completion: 0.2, skipped: true)
        try insertEvent(database, startedAt: Instant.may2024 + 120, artist: "Other", completion: 0.95)

        try await makeCompactor(database).compact()

        let rolled = try rollups(database)
        #expect(rolled.count == 2)
        let artist = try #require(rolled.first { $0.artistKey == "Artist" })
        #expect(artist.plays == 2)
        #expect(artist.skips == 1)
        #expect(artist.completions == 1)
        let other = try #require(rolled.first { $0.artistKey == "Other" })
        #expect(other.plays == 1)
        #expect(other.completions == 1)
    }

    @Test("a NULL artist or genre collapses into the empty-string sentinel bucket")
    func unknownKeysUseTheSentinel() async throws {
        let database = try makeDatabase()
        try insertEvent(database, startedAt: Instant.may2024, artist: nil, genre: nil)
        try insertEvent(database, startedAt: Instant.may2024 + 60, artist: nil, genre: nil)

        try await makeCompactor(database).compact()

        let rolled = try rollups(database)
        #expect(rolled.count == 1)
        #expect(rolled.first?.artistKey == PlayEventRollupRecord.unknownKey)
        #expect(rolled.first?.genreKey == PlayEventRollupRecord.unknownKey)
        #expect(rolled.first?.plays == 2)
    }

    @Test("listened seconds sum in whole microseconds, so the total is order-independent")
    func listenedSecondsAreQuantized() async throws {
        let database = try makeDatabase()
        // Ten 0.1 s plays. A REAL `SUM` would land on 0.9999999999999999 and would
        // depend on the order SQLite happened to visit the rows in.
        for index in 0 ..< 10 {
            try insertEvent(database, startedAt: Instant.may2024 + Double(index), listened: 0.1)
        }

        try await makeCompactor(database).compact()

        let rolled = try rollups(database)
        #expect(rolled.first?.listenedSeconds == 1.0)
    }
}

// MARK: - Idempotency

@Suite("PlayEventCompactor — idempotency and late data")
struct PlayEventCompactorIdempotencyTests {
    @Test("running the same pass twice yields identical rollups and no double count")
    func secondPassChangesNothing() async throws {
        let database = try makeDatabase()
        try insertEvent(database, startedAt: Instant.may2024)
        try insertEvent(database, startedAt: Instant.may2024 + 60, listened: 42.5)
        let compactor = makeCompactor(database)

        try await compactor.compact()
        let afterFirst = try rollups(database)
        let second = try await compactor.compact()

        #expect(second.monthsCompacted == 0)
        #expect(second.eventsCompacted == 0)
        let afterSecond = try rollups(database)
        #expect(afterSecond == afterFirst)
        #expect(afterFirst.first?.plays == 2)
        let kept = try remainingEvents(database)
        #expect(kept.isEmpty)
    }

    @Test("backdated events fold into the EXISTING rollup row rather than duplicating it")
    func backdatedEventsFoldIn() async throws {
        let database = try makeDatabase()
        try insertEvent(database, startedAt: Instant.may2024, listened: 100)
        let compactor = makeCompactor(database)
        try await compactor.compact()

        // An archive import (or a late write) puts more of the SAME month back.
        try insertEvent(database, startedAt: Instant.may2024 + 3600, listened: 50, completion: 0.2, skipped: true)
        try insertEvent(database, startedAt: Instant.may2024 + 7200, listened: 25, completion: 0.1)
        try await compactor.compact()

        let rolled = try rollups(database)
        #expect(rolled.count == 1)
        let row = try #require(rolled.first)
        #expect(row.yearMonth == "2024-05")
        #expect(row.plays == 3)
        #expect(row.listenedSeconds == 175)
        #expect(row.skips == 1)
        #expect(row.completions == 1)
        let kept = try remainingEvents(database)
        #expect(kept.isEmpty)
    }
}

// MARK: - Atomicity

@Suite("PlayEventCompactor — atomicity")
struct PlayEventCompactorAtomicityTests {
    /// Fails the DELETE step from inside SQLite, so the failure is injected without
    /// any test-only hook in the production type.
    private func blockDeletes(_ database: AppDatabase) throws {
        try database.writer.write { db in
            try db.execute(sql: """
            CREATE TRIGGER blockPlayEventDelete BEFORE DELETE ON playEvent
            BEGIN SELECT RAISE(ABORT, 'compaction blocked'); END
            """)
        }
    }

    private func unblockDeletes(_ database: AppDatabase) throws {
        try database.writer.write { db in
            try db.execute(sql: "DROP TRIGGER blockPlayEventDelete")
        }
    }

    @Test("a failure mid-pass rolls the whole pass back: no rollups, no lost raw events")
    func failedPassRollsBackCompletely() async throws {
        let database = try makeDatabase()
        try insertEvent(database, startedAt: Instant.may2024)
        try insertEvent(database, startedAt: Instant.lastAgedSecond)
        try blockDeletes(database)
        let compactor = makeCompactor(database)

        var failed = false
        do {
            try await compactor.compact()
        } catch {
            failed = true
        }

        #expect(failed)
        // The rollup upserts ran BEFORE the delete that failed; if the transaction
        // were not atomic they would still be here, and the next successful pass
        // would count the same events a second time.
        let rolledAfterFailure = try rollups(database)
        #expect(rolledAfterFailure.isEmpty)
        let keptAfterFailure = try remainingEvents(database)
        #expect(keptAfterFailure.count == 2)

        // And the pass is simply retryable once the failure clears.
        try unblockDeletes(database)
        let retry = try await compactor.compact()
        #expect(retry.eventsCompacted == 2)
        let rolled = try rollups(database)
        #expect(rolled.count == 2)
        let kept = try remainingEvents(database)
        #expect(kept.isEmpty)
    }
}

// MARK: - Segment heat

@Suite("PlayEventCompactor — playSegmentHeat is never aged")
struct PlayEventCompactorSegmentHeatTests {
    @Test("compaction leaves every playSegmentHeat row byte-identical")
    func segmentHeatIsUntouched() async throws {
        let database = try makeDatabase()
        var counts = [UInt32](repeating: 0, count: PlaySegmentHeatRecord.bucketCount)
        counts[0] = 7
        counts[PlaySegmentHeatRecord.bucketCount - 1] = 3
        let seeded = try insertSegmentHeat(database, counts: counts)
        try insertEvent(database, startedAt: Instant.may2024)

        try await makeCompactor(database).compact()

        let after = try segmentHeatRows(database)
        #expect(after == [seeded])
        // The events that produced it are gone; the aggregate is not.
        let kept = try remainingEvents(database)
        #expect(kept.isEmpty)
    }
}
