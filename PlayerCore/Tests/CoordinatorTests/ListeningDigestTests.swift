// ListeningDigestTests — what the seeded fixture must produce, facet by facet.
//
// Every expected figure below is hand-computed from `ListeningDigestHarness.swift`.
// See that file for the six plays, the rollup and the three heatmaps, and for the UTC
// instants each window boundary sits on.
import Foundation
import GRDB
import Persistence
import PlayerCoreTestSupport
@testable import Services
import Testing

private func histogram(_ counts: [Int: Int], bins: Int) -> [Int] {
    var values = [Int](repeating: 0, count: bins)
    for (index, count) in counts {
        values[index] = count
    }
    return values
}

private func hours(_ counts: [Int: Int]) -> [Int] {
    histogram(counts, bins: ListeningLocalTime.hoursPerDay)
}

private func weekdays(_ counts: [Int: Int]) -> [Int] {
    histogram(counts, bins: ListeningLocalTime.daysPerWeek)
}

private func seededDigest() async throws -> ListeningDigest {
    let database = try makeDigestDatabase()
    try seedDigestFixture(database)
    return try await makeDigestBuilder(database).buildDigest(profileId: DigestFixture.profileId)
}

private func window(
    _ digest: ListeningDigest,
    _ kind: ListeningWindowKind
) throws -> ListeningWindowDigest {
    try #require(digest.window(kind))
}

@Suite("ListeningDigest")
struct ListeningDigestTests {
    // MARK: - Shape

    @Test("the digest is versioned and carries all four windows in declaration order")
    func shape() async throws {
        let digest = try await seededDigest()
        #expect(digest.digestVersion == 1)
        #expect(digest.generatedAt == Int64(DigestInstant.now))
        #expect(digest.rawHorizonYearMonth == "2024-07")
        #expect(digest.windows.map(\.window) == ListeningWindowKind.allCases)
    }

    @Test("window bounds are the injected clock's, measured in days and CIVIL months")
    func windowBounds() async throws {
        let digest = try await seededDigest()
        let expected: [ListeningWindowKind: Double] = [
            .last7Days: DigestInstant.sevenDayStart,
            .last30Days: DigestInstant.thirtyDayStart,
            .last12Months: DigestInstant.twelveMonthStart,
            .allTime: 0,
        ]
        for (kind, start) in expected {
            let facet = try window(digest, kind)
            #expect(facet.startedAt == Int64(start))
            #expect(facet.endedAt == Int64(DigestInstant.now))
        }
    }

    // MARK: - Per-window facets

    @Test("the seven-day window sees only the three most recent plays")
    func sevenDayWindow() async throws {
        let facet = try await window(seededDigest(), .last7Days)
        #expect(facet.totalPlays == 3)
        #expect(facet.skips == 1)
        #expect(facet.skipRate == 0.3333)
        #expect(facet.completions == 2)
        #expect(facet.meanCompletion == 0.7567)
        #expect(facet.totalListenedSeconds == 480.5)
        #expect(facet.topTracks.map(\.track.identityKey) == ["artist a|song a|album a", "artist a|song b|album a"])
        #expect(facet.topTracks.map(\.plays) == [2, 1])
        #expect(facet.topArtists.map(\.name) == ["Artist A"])
        #expect(facet.topGenres.map(\.name) == ["Rock"])
        #expect(facet.hourHistogram == hours([10: 1, 16: 1, 18: 1]))
        #expect(facet.weekdayHistogram == weekdays([1: 1, 2: 1, 3: 1]))
    }

    @Test("the twelve-month window adds the daylight-saving pair, both at local 04:00")
    func twelveMonthWindow() async throws {
        let facet = try await window(seededDigest(), .last12Months)
        #expect(facet.totalPlays == 5)
        #expect(facet.skipRate == 0.2)
        #expect(facet.completions == 3)
        #expect(facet.meanCompletion == 0.734)
        #expect(facet.totalListenedSeconds == 780.75)
        #expect(facet.hourHistogram == hours([4: 2, 10: 1, 16: 1, 18: 1]))
        #expect(facet.weekdayHistogram == weekdays([1: 1, 2: 1, 3: 1, 6: 2]))
        let top = try #require(facet.topTracks.first)
        #expect(top.plays == 4)
        #expect(top.skips == 1)
        #expect(top.completions == 2)
        #expect(top.meanCompletion == 0.6675)
        #expect(top.listenedSeconds == 540.75)
        #expect(top.lastPlayedAt == Int64(DigestInstant.tuesdayEvening))
    }

    @Test("perTrackHours is published for the 30-day and 12-month windows only")
    func perTrackHoursHorizon() async throws {
        let digest = try await seededDigest()
        #expect(try window(digest, .last7Days).perTrackHours.isEmpty)
        #expect(try window(digest, .allTime).perTrackHours.isEmpty)
        let monthly = try window(digest, .last30Days)
        #expect(monthly.perTrackHours.map(\.track.identityKey) == monthly.topTracks.map(\.track.identityKey))
        #expect(monthly.perTrackHours.first?.hours == hours([10: 1, 18: 1]))
        let yearly = try window(digest, .last12Months)
        #expect(yearly.perTrackHours.first?.hours == hours([4: 2, 10: 1, 18: 1]))
    }

    @Test("dayparts tile the day and rank each block's own tracks")
    func dayparts() async throws {
        let facet = try await window(seededDigest(), .last12Months)
        #expect(facet.dayparts.map(\.daypart) == ListeningDaypart.allCases)
        #expect(facet.dayparts.map(\.plays) == [2, 1, 1, 1])
        // The two 04:00 plays are the same track, so night lists it once with two plays.
        let night = try #require(facet.dayparts.first)
        #expect(night.topTracks.map(\.track.identityKey) == ["artist a|song a|album a"])
        #expect(night.topTracks.map(\.plays) == [2])
        // Every play is accounted for exactly once across the four blocks.
        #expect(facet.dayparts.reduce(0) { $0 + $1.plays } == facet.totalPlays)
    }

    @Test("tied daypart tracks fall back to identity key, never to scan order")
    func daypartTieBreak() async throws {
        let facet = try await window(seededDigest(), .allTime)
        let evening = try #require(facet.dayparts.last)
        #expect(evening.plays == 2)
        #expect(evening.topTracks.map(\.track.identityKey) == [
            "artist a|song a|album a",
            "artist b|song c|album b",
        ])
    }

    // MARK: - The raw ∪ rollup union

    @Test("the all-time window unions raw events with rollups, counting neither twice")
    func allTimeUnion() async throws {
        let facet = try await window(seededDigest(), .allTime)
        #expect(facet.totalPlays == 16) // six raw + ten rolled up
        #expect(facet.skips == 4) // one raw + three rolled up
        #expect(facet.skipRate == 0.25)
        #expect(facet.completions == 10) // four raw + six rolled up
        #expect(facet.totalListenedSeconds == 2581.25) // 1080.75 raw + 1500.5 rolled up
        let artist = try #require(facet.topArtists.first)
        #expect(artist.name == "Artist A")
        #expect(artist.plays == 15)
        #expect(artist.listenedSeconds == 2281.25)
        #expect(artist.lastPlayedAt == Int64(DigestInstant.wednesdayAfternoon))
        #expect(facet.topGenres.map(\.name) == ["Rock", "Jazz"])
        #expect(facet.topGenres.map(\.plays) == [15, 1])
    }

    @Test("track-level facets stay RAW — a rollup carries no track identity to add")
    func rollupsNeverReachTracks() async throws {
        let facet = try await window(seededDigest(), .allTime)
        #expect(facet.topTracks.map(\.plays).reduce(0, +) == 6)
        #expect(facet.meanCompletion == 0.7767) // raw only: 4.66 / 6
        #expect(facet.hourHistogram.reduce(0, +) == 6)
        #expect(facet.weekdayHistogram.reduce(0, +) == 6)
    }

    @Test("a rollup-only name reports no recency, because a rollup keeps no timestamp")
    func rollupOnlyNameHasNoRecency() async throws {
        let database = try makeDigestDatabase()
        try insertDigestRollup(database, artist: "Ghost", genre: "Ambient")
        let digest = try await makeDigestBuilder(database).buildDigest(profileId: DigestFixture.profileId)
        let facet = try window(digest, .allTime)
        #expect(facet.topArtists.map(\.name) == ["Ghost"])
        #expect(facet.topArtists.first?.lastPlayedAt == nil)
        #expect(facet.topArtists.first?.plays == 10)
    }

    @Test("an unknown artist or genre collapses to the rollup's own empty-string key")
    func unknownKeysMatchTheRollupSentinel() async throws {
        let database = try makeDigestDatabase()
        try insertDigestEvent(database, DigestEventSeed(
            trackId: nil, artist: nil, title: "Untagged", album: nil, genre: nil,
            startedAt: DigestInstant.mondayMorning, utcOffsetSeconds: 0
        ))
        try insertDigestRollup(
            database,
            artist: PlayEventRollupRecord.unknownKey,
            genre: PlayEventRollupRecord.unknownKey,
            plays: 4
        )
        let digest = try await makeDigestBuilder(database).buildDigest(profileId: DigestFixture.profileId)
        let facet = try window(digest, .allTime)
        #expect(facet.topArtists.map(\.name) == [""])
        #expect(facet.topArtists.first?.plays == 5)
        #expect(facet.topTracks.first?.track.identityKey == "|untagged|")
    }

    // MARK: - Replay

    @Test("mostReplayed is a LIFETIME list, affinity-ranked, floored on trust")
    func mostReplayed() async throws {
        let digest = try await seededDigest()
        #expect(digest.mostReplayed.map(\.track.identityKey) == [
            "artist a|song a|album a",
            "artist b|song d|album b",
            "artist a|song b|album a",
        ])
        let chorus = try #require(digest.mostReplayed.first)
        #expect(chorus.replayAffinity == 0.434)
        #expect(chorus.totalPasses == 5)
        #expect(chorus.totalListens == 159)
        #expect(chorus.durationSeconds == 250)
        #expect(chorus.clusters.map(\.startPercent) == [30, 70])
        #expect(chorus.clusters.map(\.endPercent) == [35, 72])
        #expect(chorus.clusters.map(\.intensity) == [1, 0.8])
        let even = try #require(digest.mostReplayed.last)
        #expect(even.replayAffinity == 0.1)
        #expect(even.clusters.count == 1)
    }

    @Test("a heatmap that clears neither half of the trust floor is absent")
    func replayTrustFloor() async throws {
        let digest = try await seededDigest()
        // Song C was heard twice, evenly: two passes, and no slice heard three times.
        #expect(digest.mostReplayed.contains { $0.track.identityKey == "artist b|song c|album b" } == false)
    }

    @Test("one sitting that replayed a passage ranks without a second pass")
    func replayPeakFloorAdmitsOneSitting() async throws {
        let digest = try await seededDigest()
        let single = try #require(digest.mostReplayed.first { $0.track.identityKey == "artist b|song d|album b" })
        #expect(single.totalPasses == 1)
        #expect(single.totalListens == 109)
        #expect(single.replayAffinity == 0.1743)
        #expect(single.clusters.map(\.startPercent) == [50])
        #expect(single.clusters.map(\.endPercent) == [53])
    }

    // MARK: - Survivability and emptiness

    @Test("an empty profile still produces a well-formed digest")
    func emptyProfile() async throws {
        let database = try makeDigestDatabase()
        let digest = try await makeDigestBuilder(database).buildDigest(profileId: DigestFixture.profileId)
        #expect(digest.digestVersion == 1)
        #expect(digest.windows.count == ListeningWindowKind.allCases.count)
        #expect(digest.mostReplayed.isEmpty)
        for facet in digest.windows {
            #expect(facet.totalPlays == 0)
            #expect(facet.skipRate == 0)
            #expect(facet.meanCompletion == 0)
            #expect(facet.topTracks.isEmpty)
            #expect(facet.hourHistogram == hours([:]))
            #expect(facet.weekdayHistogram == weekdays([:]))
            #expect(facet.dayparts.map(\.plays) == [0, 0, 0, 0])
        }
        let encoded = try digest.encodedJSON()
        #expect(encoded.isEmpty == false)
    }

    @Test("deleting every track row changes NOT ONE BYTE of the digest")
    func survivesTrackDeletion() async throws {
        let database = try makeDigestDatabase()
        try seedDigestFixture(database)
        let before = try await buildDigestJSON(database)
        let survivors = try deleteAllTracks(database)
        #expect(survivors == 0)
        let after = try await buildDigestJSON(database)
        #expect(after == before)
    }
}
