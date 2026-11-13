import Foundation
import GRDB
import Persistence
import Testing

/// Coverage for the two read-only statistics aggregates added to the `v15` listening
/// history — the per-track lifetime aggregate and the snapshot-keyed top-track ranking.
///
/// The nil-for-no-rows, cross-profile-isolation, `since`-cutoff and split-snapshot cases
/// are the failure paths: each one asserts the query REFUSES to count something.
@Suite("PlayEventStatsQueriesTests")
struct PlayEventStatsQueriesTests {
    private func insert(
        _ repository: PlayEventRepository,
        trackId: Int64?,
        profileId: Int64 = ProfileRecord.guestID,
        offset: Double = 0,
        title: String? = "Comfortably Numb",
        secondsListened: Double = 300,
        skipped: Bool = false
    ) async throws {
        var event = StatsFixtures.event(profileId: profileId, trackId: trackId, title: title)
        event.startedAt = StatsFixtures.startedAt + offset
        event.secondsListened = secondsListened
        event.skipped = skipped
        try await repository.insertPlayEvent(event)
    }

    // MARK: - trackPlayStats

    @Test("trackPlayStats aggregates every play of one track")
    func aggregatesOneTrack() async throws {
        let appDB = try AppDatabase.makeEmpty()
        let repository = PlayEventRepository(appDB)
        try await insert(repository, trackId: 7, offset: 0, secondsListened: 120, skipped: true)
        try await insert(repository, trackId: 7, offset: 60, secondsListened: 300)
        try await insert(repository, trackId: 7, offset: 900, secondsListened: 382)

        let stats = try await repository.trackPlayStats(
            profileId: ProfileRecord.guestID,
            trackId: 7
        )

        let resolved = try #require(stats)
        #expect(resolved.plays == 3)
        #expect(resolved.skips == 1)
        #expect(resolved.secondsListened == 802)
        #expect(resolved.firstPlayedAt == StatsFixtures.startedAt)
        #expect(resolved.lastPlayedAt == StatsFixtures.startedAt + 900)
    }

    @Test("trackPlayStats returns nil for a track with no history")
    func nilWhenNeverPlayed() async throws {
        let appDB = try AppDatabase.makeEmpty()
        let repository = PlayEventRepository(appDB)
        try await insert(repository, trackId: 7)

        let stats = try await repository.trackPlayStats(
            profileId: ProfileRecord.guestID,
            trackId: 999
        )

        #expect(stats == nil)
    }

    @Test("trackPlayStats never counts another profile's plays of the same track")
    func statsAreProfileScoped() async throws {
        let appDB = try AppDatabase.makeEmpty()
        let repository = PlayEventRepository(appDB)
        let other = try StatsFixtures.seedProfile(appDB, name: "Other")
        try await insert(repository, trackId: 7, offset: 0)
        try await insert(repository, trackId: 7, profileId: other, offset: 60)
        try await insert(repository, trackId: 7, profileId: other, offset: 120)

        let guest = try await repository.trackPlayStats(
            profileId: ProfileRecord.guestID,
            trackId: 7
        )
        let rival = try await repository.trackPlayStats(profileId: other, trackId: 7)

        let resolvedGuest = try #require(guest)
        let resolvedRival = try #require(rival)
        #expect(resolvedGuest.plays == 1)
        #expect(resolvedRival.plays == 2)
    }

    @Test("trackPlayStats returns nil when only another profile has played the track")
    func nilWhenOnlyRivalProfileHasHistory() async throws {
        let appDB = try AppDatabase.makeEmpty()
        let repository = PlayEventRepository(appDB)
        let other = try StatsFixtures.seedProfile(appDB, name: "Other")
        try await insert(repository, trackId: 7, profileId: other)

        let stats = try await repository.trackPlayStats(
            profileId: ProfileRecord.guestID,
            trackId: 7
        )

        #expect(stats == nil)
    }

    // MARK: - topTrackIds

    @Test("topTrackIds ranks by plays descending, tie-broken by ascending trackId")
    func ranksByPlaysThenTrackId() async throws {
        let appDB = try AppDatabase.makeEmpty()
        let repository = PlayEventRepository(appDB)
        for offset in 0 ..< 3 {
            try await insert(repository, trackId: 30, offset: Double(offset))
        }
        try await insert(repository, trackId: 20, offset: 10)
        try await insert(repository, trackId: 10, offset: 20)

        let top = try await repository.topTrackIds(
            profileId: ProfileRecord.guestID,
            since: 0,
            limit: 50
        )

        #expect(top.map(\.trackId) == [30, 10, 20])
        #expect(top.map(\.plays) == [3, 1, 1])
    }

    @Test("topTrackIds excludes plays that began before the cutoff")
    func respectsSinceCutoff() async throws {
        let appDB = try AppDatabase.makeEmpty()
        let repository = PlayEventRepository(appDB)
        try await insert(repository, trackId: 10, offset: 0)
        try await insert(repository, trackId: 20, offset: 500)
        try await insert(repository, trackId: 20, offset: 600)

        let top = try await repository.topTrackIds(
            profileId: ProfileRecord.guestID,
            since: StatsFixtures.startedAt + 100,
            limit: 50
        )

        #expect(top.map(\.trackId) == [20])
        #expect(top.map(\.plays) == [2])
    }

    @Test("topTrackIds treats the cutoff as inclusive")
    func cutoffIsInclusive() async throws {
        let appDB = try AppDatabase.makeEmpty()
        let repository = PlayEventRepository(appDB)
        try await insert(repository, trackId: 10, offset: 100)

        let top = try await repository.topTrackIds(
            profileId: ProfileRecord.guestID,
            since: StatsFixtures.startedAt + 100,
            limit: 50
        )

        #expect(top.map(\.trackId) == [10])
    }

    @Test("topTrackIds skips events that carry no track backlink")
    func skipsNullTrackIds() async throws {
        let appDB = try AppDatabase.makeEmpty()
        let repository = PlayEventRepository(appDB)
        try await insert(repository, trackId: nil, offset: 0)
        try await insert(repository, trackId: nil, offset: 10)
        try await insert(repository, trackId: 10, offset: 20)

        let top = try await repository.topTrackIds(
            profileId: ProfileRecord.guestID,
            since: 0,
            limit: 50
        )

        #expect(top.map(\.trackId) == [10])
        #expect(top.map(\.plays) == [1])
    }

    @Test("topTrackIds never counts another profile's plays")
    func topIsProfileScoped() async throws {
        let appDB = try AppDatabase.makeEmpty()
        let repository = PlayEventRepository(appDB)
        let other = try StatsFixtures.seedProfile(appDB, name: "Other")
        try await insert(repository, trackId: 10, offset: 0)
        try await insert(repository, trackId: 20, profileId: other, offset: 10)
        try await insert(repository, trackId: 20, profileId: other, offset: 20)

        let top = try await repository.topTrackIds(
            profileId: ProfileRecord.guestID,
            since: 0,
            limit: 50
        )

        #expect(top.map(\.trackId) == [10])
    }

    @Test("topTrackIds honours the requested limit")
    func respectsLimit() async throws {
        let appDB = try AppDatabase.makeEmpty()
        let repository = PlayEventRepository(appDB)
        for trackId in Int64(1) ... 6 {
            try await insert(repository, trackId: trackId, offset: Double(trackId))
        }

        let top = try await repository.topTrackIds(
            profileId: ProfileRecord.guestID,
            since: 0,
            limit: 2
        )

        #expect(top.count == 2)
    }

    @Test("topTrackIds returns the capture-time snapshot columns verbatim")
    func returnsSnapshotColumns() async throws {
        let appDB = try AppDatabase.makeEmpty()
        let repository = PlayEventRepository(appDB)
        try await insert(repository, trackId: 10, title: "Hey You")

        let top = try await repository.topTrackIds(
            profileId: ProfileRecord.guestID,
            since: 0,
            limit: 50
        )

        let row = try #require(top.first)
        #expect(row.artistName == "Pink Floyd")
        #expect(row.title == "Hey You")
        #expect(row.albumTitle == "The Wall")
    }

    /// The grouping is intentionally finer than the digest's case-folded identity: one
    /// retagged track yields one row per distinct snapshot, which is exactly why callers
    /// pass a doubled limit.
    @Test("topTrackIds splits one trackId across two differing title snapshots")
    func splitsRetaggedSnapshots() async throws {
        let appDB = try AppDatabase.makeEmpty()
        let repository = PlayEventRepository(appDB)
        try await insert(repository, trackId: 10, offset: 0, title: "Comfortably Numb")
        try await insert(repository, trackId: 10, offset: 10, title: "Comfortably Numb")
        try await insert(repository, trackId: 10, offset: 20, title: "Comfortably Numb (Remaster)")

        let top = try await repository.topTrackIds(
            profileId: ProfileRecord.guestID,
            since: 0,
            limit: 50
        )

        #expect(top.count == 2)
        #expect(top.allSatisfy { $0.trackId == 10 })
        #expect(top.map(\.plays) == [2, 1])
        #expect(top.map(\.title) == ["Comfortably Numb", "Comfortably Numb (Remaster)"])
    }

    @Test("topTrackIds returns nothing for a profile with no history")
    func emptyWhenNoHistory() async throws {
        let appDB = try AppDatabase.makeEmpty()
        let repository = PlayEventRepository(appDB)

        let top = try await repository.topTrackIds(
            profileId: ProfileRecord.guestID,
            since: 0,
            limit: 50
        )

        #expect(top.isEmpty)
    }
}
