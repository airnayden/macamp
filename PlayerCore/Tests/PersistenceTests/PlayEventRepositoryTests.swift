import Foundation
import GRDB
import Persistence
import Testing

/// Bounded read/write coverage for the `v15` listening-history repository —
/// acceptance criterion (m) of the stats-expansion plan's todo 2.
@Suite("PlayEventRepositoryTests")
struct PlayEventRepositoryTests {
    private func seed(_ repository: PlayEventRepository, count: Int, profileId: Int64) async throws {
        for index in 0 ..< count {
            var event = StatsFixtures.event(profileId: profileId, trackId: Int64(index))
            event.startedAt = StatsFixtures.startedAt + Double(index)
            event.title = "track-\(index)"
            try await repository.insertPlayEvent(event)
        }
    }

    private func drainEvents(
        _ repository: PlayEventRepository,
        profileId: Int64,
        pageSize: Int
    ) async throws -> [PlayEventRecord] {
        var collected: [PlayEventRecord] = []
        var cursor: PageCursor<Double>?
        while true {
            let page = try await repository.playEvents(
                profileId: profileId,
                before: cursor,
                limit: pageSize
            )
            collected.append(contentsOf: page.items)
            guard let next = page.nextCursor else { break }
            cursor = next
        }
        return collected
    }

    @Test("insertPlayEvent returns the assigned rowid and the row round-trips")
    func insertRoundTrips() async throws {
        let appDB = try AppDatabase.makeEmpty()
        let repository = PlayEventRepository(appDB)

        let rowID = try await repository.insertPlayEvent(StatsFixtures.event(trackId: 5))

        #expect(rowID > 0)
        let page = try await repository.playEvents(profileId: ProfileRecord.guestID)
        #expect(page.items.count == 1)
        #expect(page.items.first?.id == rowID)
        #expect(page.items.first?.trackId == 5)
    }

    @Test("(m) the keyset pages every event exactly once, newest first, with no duplicates")
    func keysetPaginatesWithoutDuplicates() async throws {
        let appDB = try AppDatabase.makeEmpty()
        let repository = PlayEventRepository(appDB)
        try await seed(repository, count: 25, profileId: ProfileRecord.guestID)

        let collected = try await drainEvents(repository, profileId: ProfileRecord.guestID, pageSize: 7)

        #expect(collected.count == 25)
        #expect(Set(collected.compactMap(\.id)).count == 25)
        #expect(collected.map(\.startedAt) == collected.map(\.startedAt).sorted(by: >))
        #expect(collected.first?.title == "track-24")
        #expect(collected.last?.title == "track-0")
    }

    @Test("(m) a page never exceeds the repository's hard ceiling")
    func pageLimitIsCapped() async throws {
        let appDB = try AppDatabase.makeEmpty()
        let repository = PlayEventRepository(appDB)
        try await seed(repository, count: 12, profileId: ProfileRecord.guestID)

        let page = try await repository.playEvents(
            profileId: ProfileRecord.guestID,
            before: nil,
            limit: PlayEventRepository.fetchLimit * 10
        )

        #expect(page.items.count == 12)
        #expect(page.nextCursor == nil)
    }

    @Test("(m) events are scoped to their profile")
    func eventsAreProfileScoped() async throws {
        let appDB = try AppDatabase.makeEmpty()
        let repository = PlayEventRepository(appDB)
        let other = try StatsFixtures.seedProfile(appDB, name: "Other")
        try await seed(repository, count: 3, profileId: ProfileRecord.guestID)
        try await seed(repository, count: 5, profileId: other)

        let guestPage = try await repository.playEvents(profileId: ProfileRecord.guestID)
        let otherPage = try await repository.playEvents(profileId: other)

        #expect(guestPage.items.count == 3)
        #expect(otherPage.items.count == 5)
    }

    @Test("(m) deleteEventsOlderThan is batch-bounded and leaves newer events alone")
    func deleteIsBounded() async throws {
        let appDB = try AppDatabase.makeEmpty()
        let repository = PlayEventRepository(appDB)
        try await seed(repository, count: 20, profileId: ProfileRecord.guestID)
        let cutoff = StatsFixtures.startedAt + 15

        let firstBatch = try await repository.deleteEventsOlderThan(
            cutoff,
            profileId: ProfileRecord.guestID,
            limit: 6
        )
        let secondBatch = try await repository.deleteEventsOlderThan(
            cutoff,
            profileId: ProfileRecord.guestID,
            limit: 100
        )
        let exhausted = try await repository.deleteEventsOlderThan(
            cutoff,
            profileId: ProfileRecord.guestID,
            limit: 100
        )

        #expect(firstBatch == 6)
        #expect(secondBatch == 9)
        #expect(exhausted == 0)
        let remaining = try await drainEvents(repository, profileId: ProfileRecord.guestID, pageSize: 50)
        #expect(remaining.count == 5)
        #expect(remaining.allSatisfy { $0.startedAt >= cutoff })
    }

    @Test("(m) deleteEventsOlderThan never touches another profile's history")
    func deleteIsProfileScoped() async throws {
        let appDB = try AppDatabase.makeEmpty()
        let repository = PlayEventRepository(appDB)
        let other = try StatsFixtures.seedProfile(appDB, name: "Other")
        try await seed(repository, count: 4, profileId: ProfileRecord.guestID)
        try await seed(repository, count: 4, profileId: other)

        let deleted = try await repository.deleteEventsOlderThan(
            StatsFixtures.startedAt + 100,
            profileId: ProfileRecord.guestID,
            limit: 100
        )

        #expect(deleted == 4)
        let otherPage = try await repository.playEvents(profileId: other)
        #expect(otherPage.items.count == 4)
    }

    @Test("(m) upsertRollup is idempotent — a re-run replaces rather than accumulates")
    func rollupUpsertIsIdempotent() async throws {
        let appDB = try AppDatabase.makeEmpty()
        let repository = PlayEventRepository(appDB)
        let rollup = PlayEventRollupRecord(
            profileId: ProfileRecord.guestID,
            yearMonth: "2026-07",
            artistKey: "Pink Floyd",
            genreKey: "Progressive Rock",
            plays: 4,
            listenedSeconds: 900,
            skips: 1,
            completions: 3
        )

        try await repository.upsertRollup(rollup)
        try await repository.upsertRollup(rollup)
        var revised = rollup
        revised.plays = 9
        try await repository.upsertRollup(revised)

        let page = try await repository.rollups(profileId: ProfileRecord.guestID)
        #expect(page.items.count == 1)
        #expect(page.items.first?.plays == 9)
        #expect(page.items.first?.listenedSeconds == 900)
    }

    @Test("(m) rollups page by month without duplicates")
    func rollupsPaginate() async throws {
        let appDB = try AppDatabase.makeEmpty()
        let repository = PlayEventRepository(appDB)
        for month in 1 ... 9 {
            try await repository.upsertRollup(
                PlayEventRollupRecord(
                    profileId: ProfileRecord.guestID,
                    yearMonth: String(format: "2026-%02d", month),
                    artistKey: "Artist \(month)",
                    plays: month
                )
            )
        }

        var collected: [PlayEventRollupRecord] = []
        var cursor: PageCursor<String>?
        while true {
            let page = try await repository.rollups(
                profileId: ProfileRecord.guestID,
                after: cursor,
                limit: 4
            )
            collected.append(contentsOf: page.items)
            guard let next = page.nextCursor else { break }
            cursor = next
        }

        #expect(collected.count == 9)
        #expect(Set(collected.map(\.yearMonth)).count == 9)
        #expect(collected.map(\.yearMonth) == collected.map(\.yearMonth).sorted())
    }
}
