// ListeningDigestHarness — the one seeded fixture every digest suite builds on.
//
// `now` is pinned to 2026-07-25T00:00:00Z (a Saturday) throughout, which places the
// four windows at:
//
//     last7Days     2026-07-18T00:00:00Z … now
//     last30Days    2026-06-25T00:00:00Z … now
//     last12Months  2025-08-01T00:00:00Z … now   (twelve CIVIL months)
//     allTime       the epoch            … now
//
// and the compactor's raw horizon at 2024-07. Every instant below is hand-computed
// UTC so no assertion depends on the machine's calendar, and every one of them is far
// past `epoch + 1 day` — the digest's `localSeconds >= 0` clamp must never be the
// thing that makes a test pass.
//
// The six events are chosen so that each window contains a different subset, and so
// that the local-hour arithmetic is exercised across a positive offset, a NEGATIVE
// offset, the widest real offset (+14 h) and a daylight-saving PAIR (two plays at the
// same local hour whose UTC hours and offsets both differ).
import Foundation
import GRDB
import Persistence
import PlayerCoreTestSupport
@testable import Services
import Testing

// MARK: - Fixture instants (UTC, hand-computed)

enum DigestInstant {
    /// 2026-07-25T00:00:00Z — the pinned "now" for every digest test.
    static let now: Double = 1_784_937_600
    /// 2026-07-18T00:00:00Z — the start of the seven-day window.
    static let sevenDayStart: Double = 1_784_332_800
    /// 2026-06-25T00:00:00Z — the start of the thirty-day window.
    static let thirtyDayStart: Double = 1_782_345_600
    /// 2025-08-01T00:00:00Z — the start of the twelve-civil-month window.
    static let twelveMonthStart: Double = 1_754_006_400

    /// 2026-07-20T09:00:00Z, Monday. With +01:00 this is local Monday 10:00.
    static let mondayMorning: Double = 1_784_538_000
    /// 2026-07-21T23:30:00Z, Tuesday. With −05:00 this is local Tuesday 18:30.
    static let tuesdayEvening: Double = 1_784_676_600
    /// 2026-07-22T02:00:00Z, Wednesday. With +14:00 this is local Wednesday 16:00.
    static let wednesdayAfternoon: Double = 1_784_685_600
    /// 2026-03-07T12:00:00Z, Saturday. With −08:00 (winter) this is local 04:00.
    static let dstBefore: Double = 1_772_884_800
    /// 2026-03-14T11:00:00Z, Saturday. With −07:00 (summer) this is ALSO local 04:00.
    static let dstAfter: Double = 1_773_486_000
    /// 2025-02-10T20:00:00Z, Monday. Raw, but older than the twelve-month window.
    static let lastYearEvening: Double = 1_739_217_600
}

// MARK: - Seeds

/// One play to insert. Defaults describe a complete, unskipped listen.
struct DigestEventSeed {
    var trackId: Int64?
    var artist: String?
    var title: String?
    var album: String?
    var genre: String?
    var startedAt: Double
    var utcOffsetSeconds: Int
    var duration: Double? = 250
    var listened: Double = 250
    var completion: Double = 1
    var skipped = false
}

struct DigestHeatSeed {
    var trackId: Int64
    var artist: String?
    var title: String?
    var album: String?
    var genre: String?
    var duration: Double
    var buckets: [UInt32]
    var totalPasses: Int
}

enum DigestFixture {
    static let profileId = ProfileRecord.guestID

    /// The six seeded plays, in a deliberately unsorted order.
    static let events: [DigestEventSeed] = [
        DigestEventSeed(
            trackId: 1, artist: "Artist A", title: "Song A", album: "Album A", genre: "Rock",
            startedAt: DigestInstant.mondayMorning, utcOffsetSeconds: 3600,
            listened: 180, completion: 0.95
        ),
        DigestEventSeed(
            trackId: 1, artist: "Artist A", title: "Song A", album: "Album A", genre: "Rock",
            startedAt: DigestInstant.tuesdayEvening, utcOffsetSeconds: -18000,
            listened: 60.5, completion: 0.32, skipped: true
        ),
        DigestEventSeed(
            trackId: 2, artist: "Artist A", title: "Song B", album: "Album A", genre: "Rock",
            startedAt: DigestInstant.wednesdayAfternoon, utcOffsetSeconds: 50400,
            listened: 240, completion: 1
        ),
        DigestEventSeed(
            trackId: 1, artist: "Artist A", title: "Song A", album: "Album A", genre: "Rock",
            startedAt: DigestInstant.dstBefore, utcOffsetSeconds: -28800,
            listened: 200.25, completion: 0.9
        ),
        DigestEventSeed(
            trackId: 1, artist: "Artist A", title: "Song A", album: "Album A", genre: "Rock",
            startedAt: DigestInstant.dstAfter, utcOffsetSeconds: -25200,
            listened: 100, completion: 0.5
        ),
        DigestEventSeed(
            trackId: 3, artist: "Artist B", title: "Song C", album: "Album B", genre: "Jazz",
            startedAt: DigestInstant.lastYearEvening, utcOffsetSeconds: 0,
            listened: 300, completion: 0.99
        ),
    ]

    /// A chorus-heavy heatmap: baseline 1, buckets 30–34 at 10, buckets 70–71 at 8.
    static var chorusBuckets: [UInt32] {
        var buckets = [UInt32](repeating: 1, count: PlaySegmentHeatRecord.bucketCount)
        for index in 30 ... 34 {
            buckets[index] = 10
        }
        for index in 70 ... 71 {
            buckets[index] = 8
        }
        return buckets
    }

    /// A perfectly even heatmap — one cluster spanning the whole track, affinity 0.1.
    static var evenBuckets: [UInt32] {
        [UInt32](repeating: 3, count: PlaySegmentHeatRecord.bucketCount)
    }

    /// Two unbroken listens: no slice reaches three, so neither half of the trust
    /// floor is met and the row must stay out of the ranking.
    static var quietBuckets: [UInt32] {
        [UInt32](repeating: 2, count: PlaySegmentHeatRecord.bucketCount)
    }

    /// ONE sitting in which a passage was rewound to four times — the shape the
    /// pass-count-only floor used to hide.
    static var oneSittingReplayBuckets: [UInt32] {
        var buckets = [UInt32](repeating: 1, count: PlaySegmentHeatRecord.bucketCount)
        for index in 50 ... 52 {
            buckets[index] = 4
        }
        return buckets
    }

    /// Four heatmaps, covering both halves of the trust floor and its refusal: two
    /// rows clear it on passes, the fourth clears it on its peak alone with a single
    /// pass, and the third clears neither and must never be reported.
    static var heatmaps: [DigestHeatSeed] {
        [
            DigestHeatSeed(
                trackId: 1, artist: "Artist A", title: "Song A", album: "Album A", genre: "Rock",
                duration: 250, buckets: chorusBuckets, totalPasses: 5
            ),
            DigestHeatSeed(
                trackId: 2, artist: "Artist A", title: "Song B", album: "Album A", genre: "Rock",
                duration: 300, buckets: evenBuckets, totalPasses: 4
            ),
            DigestHeatSeed(
                trackId: 3, artist: "Artist B", title: "Song C", album: "Album B", genre: "Jazz",
                duration: 200, buckets: quietBuckets, totalPasses: 2
            ),
            DigestHeatSeed(
                trackId: 4, artist: "Artist B", title: "Song D", album: "Album B", genre: "Jazz",
                duration: 220, buckets: oneSittingReplayBuckets, totalPasses: 1
            ),
        ]
    }
}

// MARK: - Database seeding

/// A migrated, empty database. Non-async by design: inside an `async` test the async
/// GRDB overloads win and every write would need an `await` that reads like a mistake.
func makeDigestDatabase() throws -> AppDatabase {
    try AppDatabase.makeEmpty()
}

@discardableResult
func insertDigestEvent(
    _ database: AppDatabase,
    _ seed: DigestEventSeed,
    profileId: Int64 = DigestFixture.profileId
) throws -> Int64 {
    try database.writer.write { db -> Int64 in
        var record = PlayEventRecord(
            profileId: profileId,
            trackId: seed.trackId,
            artistName: seed.artist,
            title: seed.title,
            albumTitle: seed.album,
            genre: seed.genre,
            durationSeconds: seed.duration,
            startedAt: seed.startedAt,
            utcOffsetSeconds: seed.utcOffsetSeconds,
            secondsListened: seed.listened,
            completionFraction: seed.completion,
            skipped: seed.skipped
        )
        try record.insert(db)
        return record.id ?? 0
    }
}

func insertDigestRollup(
    _ database: AppDatabase,
    yearMonth: String = "2023-05",
    artist: String = "Artist A",
    genre: String = "Rock",
    plays: Int = 10,
    listenedSeconds: Double = 1500.5,
    skips: Int = 3,
    completions: Int = 6,
    profileId: Int64 = DigestFixture.profileId
) throws {
    try database.writer.write { db in
        var record = PlayEventRollupRecord(
            profileId: profileId,
            yearMonth: yearMonth,
            artistKey: artist,
            genreKey: genre,
            plays: plays,
            listenedSeconds: listenedSeconds,
            skips: skips,
            completions: completions
        )
        try record.insert(db)
    }
}

func insertDigestHeat(
    _ database: AppDatabase,
    _ seed: DigestHeatSeed,
    profileId: Int64 = DigestFixture.profileId
) throws {
    let blob = try PlaySegmentHeatRecord.encodeBuckets(seed.buckets)
    try database.writer.write { db in
        var record = PlaySegmentHeatRecord(
            profileId: profileId,
            trackId: seed.trackId,
            artistName: seed.artist,
            title: seed.title,
            albumTitle: seed.album,
            genre: seed.genre,
            durationSeconds: seed.duration,
            bucketCounts: blob,
            totalPasses: seed.totalPasses,
            updatedAt: DigestInstant.now
        )
        try record.insert(db)
    }
}

/// Inserts the three library rows the seeded history refers to, so a survivability
/// test has something real to delete.
func insertDigestTracks(_ database: AppDatabase) throws {
    try database.writer.write { db in
        for index in 1 ... 3 {
            var record = TrackRecord(
                id: Int64(index),
                filePath: "/Music/track-\(index).flac",
                title: "Song \(index)",
                artistName: "Artist \(index)",
                albumTitle: "Album \(index)",
                duration: 250,
                genre: "Rock"
            )
            try record.insert(db)
        }
    }
}

/// The full fixture: three library rows, six plays, one rollup, three heatmaps (one of
/// which is below the replay-pass floor and must not appear).
func seedDigestFixture(_ database: AppDatabase, reversed: Bool = false) throws {
    try insertDigestTracks(database)
    for seed in reversed ? DigestFixture.events.reversed() : DigestFixture.events {
        try insertDigestEvent(database, seed)
    }
    try insertDigestRollup(database)
    for seed in DigestFixture.heatmaps {
        try insertDigestHeat(database, seed)
    }
}

/// Drops every library row; the statistics tables are untouched. Non-async so GRDB's
/// sync `write` overload wins — see the file header.
@discardableResult
func deleteAllTracks(_ database: AppDatabase) throws -> Int {
    try database.writer.write { db -> Int in
        try db.execute(sql: "DELETE FROM track")
        return try TrackRecord.fetchCount(db)
    }
}

func makeDigestBuilder(
    _ database: AppDatabase,
    now: Double = DigestInstant.now,
    pageSize: Int = PlayEventRepository.fetchLimit
) -> ListeningDigestBuilder {
    ListeningDigestBuilder(database, now: FakeClock(epochSeconds: now).nowProvider, pageSize: pageSize)
}

/// The seeded digest, as canonical JSON bytes.
func buildDigestJSON(
    _ database: AppDatabase,
    now: Double = DigestInstant.now,
    pageSize: Int = PlayEventRepository.fetchLimit
) async throws -> Data {
    let digest = try await makeDigestBuilder(database, now: now, pageSize: pageSize)
        .buildDigest(profileId: DigestFixture.profileId)
    return try digest.encodedJSON()
}
