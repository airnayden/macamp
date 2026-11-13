// Locks what `ListeningStatsViewModel` guarantees: one I/O pass per profile, per-window
// snapshot-keyed resolution, a replay list ranked on the digest's own basis, and a free
// window switch. Real repositories over an in-memory `AppDatabase`, behind counting spies
// and a pinned clock. The concrete `TrackRepository` cannot be spied, so that half of the
// zero-work claim rests on buffer identity instead.
import Foundation
import GRDB
import os
import Persistence
import PlayerCoreTestSupport
import Services
import Testing
import ViewModels

@MainActor
@Suite("ListeningStatsViewModelTests")
struct ListeningStatsViewModelTests {
    @Test("a load publishes four windows, builds one digest, and a reload replaces state")
    func loadPublishesEveryWindow() async throws {
        let database = try AppDatabase.makeEmpty()
        try seedBasicHistory(database)
        let harness = makeHarness(database)
        await harness.model.load(profileId: guestId)
        let digest = try #require(harness.model.digest)
        #expect(digest.windows.map(\.window) == ListeningWindowKind.allCases)
        #expect(harness.digest.calls == 1)
        #expect(harness.model.selectedWindow == .last30Days)
        #expect(harness.model.recentPlays.isEmpty == false)
        await harness.model.load(profileId: otherProfileId)
        #expect(harness.digest.calls == 2)
        #expect(harness.model.recentPlays.isEmpty)
        #expect(harness.model.replayedRows.isEmpty)
        #expect(harness.model.digest?.windows.allSatisfy { $0.totalPlays == 0 } == true)
    }

    /// Both counters are monotonic, so an unchanged SUM proves each is unchanged.
    @Test("switching the window performs no repository work and recomputes nothing")
    func switchingWindowIsFree() async throws {
        let database = try AppDatabase.makeEmpty()
        try seedBasicHistory(database)
        let harness = makeHarness(database)
        await harness.model.load(profileId: guestId)
        let calls = [harness.digest.calls, harness.repositories.calls]
        let plays = bufferAddress(harness.model.recentPlays)
        let replayed = bufferAddress(harness.model.replayedRows)
        let resolution = harness.model.topTrackResolution
        harness.model.selectedWindow = .last7Days
        #expect([harness.digest.calls, harness.repositories.calls] == calls)
        #expect(bufferAddress(harness.model.recentPlays) == plays)
        #expect(bufferAddress(harness.model.replayedRows) == replayed)
        #expect(harness.model.topTrackResolution == resolution)
        #expect(harness.model.selectedWindowDigest?.window == .last7Days)
    }

    @Test("a track played only in the last seven days resolves in that window")
    func shortWindowOnlyTrackResolves() async throws {
        let database = try AppDatabase.makeEmpty()
        try insertTrack(database, trackId: 900, title: "Fresh Cut")
        try seedCrowdedHistory(database)
        try insertEvent(database, EventSeed(trackId: 900, title: "Fresh Cut", startedAt: daysAgo(2)))
        let harness = makeHarness(database)
        await harness.model.load(profileId: guestId)
        #expect(harness.model.topTrackResolution[.allTime]?[identityKey("Fresh Cut")] == nil)
        let resolved = try #require(harness.model.topTrackResolution[.last7Days]?[identityKey("Fresh Cut")])
        #expect(resolved.track.id == 900)
    }

    @Test("a retagged track still resolves through its frozen event snapshot")
    func retaggedTrackStillResolves() async throws {
        let database = try AppDatabase.makeEmpty()
        try insertTrack(database, trackId: 7, title: "Original Title")
        try insertEvent(database, EventSeed(trackId: 7, title: "Original Title", startedAt: daysAgo(1)))
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE track SET title = 'Retagged Title' WHERE id = 7")
        }
        let harness = makeHarness(database)
        await harness.model.load(profileId: guestId)
        let resolved = try #require(harness.model.topTrackResolution[.allTime]?[identityKey("Original Title")])
        #expect(resolved.track.title == "Retagged Title")
    }

    @Test("a case-variant duplicate still resolves its digest-merged identity")
    func caseVariantDuplicateResolves() async throws {
        let database = try AppDatabase.makeEmpty()
        try insertTrack(database, trackId: 10, title: "Echoes")
        try insertTrack(database, trackId: 11, title: "ECHOES")
        try insertEvent(database, EventSeed(trackId: 10, title: "Echoes", startedAt: daysAgo(1)), times: 3)
        try insertEvent(database, EventSeed(trackId: 11, title: "ECHOES", startedAt: daysAgo(5)), times: 2)
        let harness = makeHarness(database)
        await harness.model.load(profileId: guestId)
        let digest = try #require(harness.model.digest)
        let stat = try #require(digest.window(.allTime)?.topTracks.first)
        #expect(stat.plays == 5)
        let resolved = try #require(harness.model.resolvedTopTrack(stat, in: .allTime))
        #expect(resolved.track.id == 10)
    }

    @Test("replayed rows rank exactly like the digest, affinity before passes")
    func replayedRowsMatchTheDigestRanking() async throws {
        let database = try AppDatabase.makeEmpty()
        try insertTrack(database, trackId: 20, title: "Song 20")
        try insertHeat(database, trackId: 20, buckets: spikeBuckets, passes: 4)
        try insertHeat(database, trackId: 21, buckets: flatBuckets(5), passes: 50)
        let harness = makeHarness(database)
        await harness.model.load(profileId: guestId)
        let digest = try #require(harness.model.digest)
        #expect(harness.model.replayedRows.map(\.identity) == digest.mostReplayed.map(\.track))
        let first = try #require(harness.model.replayedRows.first)
        #expect(first.trackId == 20)
        #expect(first.totalPasses == 4)
        #expect(first.intensities?.count == PlaySegmentHeatRecord.bucketCount)
        #expect(first.resolved?.track.id == 20)
    }

    @Test("one sitting that replayed a passage still earns a row")
    func replayedRowsAdmitASingleSitting() async throws {
        let database = try AppDatabase.makeEmpty()
        try insertTrack(database, trackId: 30, title: "Song 30")
        try insertHeat(database, trackId: 30, buckets: spikeBuckets, passes: 1)
        let harness = makeHarness(database)
        await harness.model.load(profileId: guestId)
        let row = try #require(harness.model.replayedRows.first)
        #expect(row.trackId == 30)
        #expect(row.totalPasses == 1)
        #expect(row.intensities?.count == PlaySegmentHeatRecord.bucketCount)
    }

    @Test("replayed rows drop rows clearing neither half and cap at the digest's limit")
    func replayedRowsAreFilteredAndCapped() async throws {
        let database = try AppDatabase.makeEmpty()
        for value in 1 ... 30 {
            try insertHeat(database, trackId: Int64(value), buckets: flatBuckets(UInt32(value)), passes: value + 3)
        }
        // Two even listens: neither the pass floor nor the peak floor is reached.
        try insertHeat(database, trackId: 99, buckets: flatBuckets(2), passes: 2)
        let harness = makeHarness(database)
        await harness.model.load(profileId: guestId)
        let digest = try #require(harness.model.digest)
        #expect(harness.model.replayedRows.count == ListeningDigestBuilder.replayEntityLimit)
        #expect(harness.model.replayedRows.contains { $0.trackId == 99 } == false)
        #expect(harness.model.replayedRows.map(\.identity) == digest.mostReplayed.map(\.track))
    }

    @Test("recent plays are newest-first, capped, and resolve only live tracks")
    func recentPlaysAreNewestFirstAndBounded() async throws {
        let database = try AppDatabase.makeEmpty()
        try insertTrack(database, trackId: 1, title: "Song 1")
        for index in 0 ..< 60 {
            let startedAt = pinnedNow - Double(index) * 3600
            let seed = EventSeed(trackId: index == 1 ? 999 : 1, title: "Song \(index)", startedAt: startedAt)
            try insertEvent(database, seed)
        }
        let harness = makeHarness(database)
        await harness.model.load(profileId: guestId)
        #expect(harness.model.recentPlays.count == ListeningStatsViewModel.recentPlaysLimit)
        #expect(harness.model.recentPlays.first?.event.title == "Song 0")
        #expect(harness.model.recentPlays.first?.resolved?.track.id == 1)
        #expect(harness.model.recentPlays[1].resolved == nil)
    }

    @Test("the completion rate is completions over plays, and the daypart is the busiest")
    func completionRateAndDaypart() async throws {
        let database = try AppDatabase.makeEmpty()
        for index in 0 ..< 4 {
            let completion = index == 3 ? 0.5 : 1
            try insertEvent(database, EventSeed(trackId: 1, startedAt: daysAgo(index + 1), completion: completion))
        }
        let harness = makeHarness(database)
        await harness.model.load(profileId: guestId)
        #expect(harness.model.completionRate(for: .allTime) == 0.75)
        #expect(harness.model.mostActiveDaypart?.daypart == .night)
        #expect(harness.model.mostActiveDaypart?.plays == 4)
    }

    @Test("an empty database yields zeroed windows, empty lists and no daypart")
    func emptyDatabaseYieldsZeroedState() async throws {
        let harness = try makeHarness(AppDatabase.makeEmpty())
        await harness.model.load(profileId: guestId)
        let digest = try #require(harness.model.digest)
        #expect(digest.windows.allSatisfy { $0.totalPlays == 0 })
        #expect(harness.model.recentPlays.isEmpty)
        #expect(harness.model.replayedRows.isEmpty)
        let resolutionIsEmpty = harness.model.topTrackResolution.values.allSatisfy(\.isEmpty)
        #expect(resolutionIsEmpty)
        #expect(harness.model.mostActiveDaypart == nil)
        #expect(harness.model.completionRate(for: .allTime) == 0)
    }

    @Test("an overlapping load is won by the last generation")
    func overlappingLoadsLastGenerationWins() async throws {
        let database = try AppDatabase.makeEmpty()
        try seedBasicHistory(database)
        let gate = Gate()
        let harness = makeHarness(database, gate: gate, gated: guestId)
        let stalled = Task { await harness.model.load(profileId: guestId) }
        while harness.digest.calls < 1 {
            await Task.yield()
        }
        await harness.model.load(profileId: otherProfileId)
        await gate.open()
        await stalled.value
        #expect(harness.digest.calls == 2)
        #expect(harness.model.recentPlays.isEmpty)
    }
}
