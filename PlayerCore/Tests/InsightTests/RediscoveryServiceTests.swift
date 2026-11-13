import Foundation
import GRDB
import Persistence
import Services
import Testing

/// ``RediscoveryService`` over scripted v15 fixtures with an injected clock.
///
/// Every instant is built from ``CivilMonth`` rather than a literal epoch number, so
/// the fixtures read as the calendar dates the product talks about and a failure
/// never depends on when the suite ran.
@Suite("RediscoveryServiceTests")
struct RediscoveryServiceTests {
    /// The reference instant every window is measured back from: 2026-08-15T12:00Z.
    private static let now = RediscoveryFixture.instant(year: 2026, month: 8, day: 15, hour: 12)
    private static let settledDay = RediscoveryFixture.instant(year: 2024, month: 1)

    @Test("A track loved in March 2025 and silent since surfaces as a forgotten favourite")
    func lovedThenSilentSurfaces() async throws {
        let fixture = try RediscoveryFixture()
        try fixture.track(id: 42, title: "Comfortably Numb", addedAt: Self.settledDay)
        try fixture.state(trackId: 42, isFavourite: true, playCount: 12)
        try fixture.play(trackId: 42, at: RediscoveryFixture.instant(year: 2025, month: 3, day: 10))

        let forgotten = try await fixture.service(now: Self.now)
            .forgottenFavourites(profileId: ProfileRecord.guestID, limit: 10)

        #expect(forgotten.map(\.trackId) == [42])
        let candidate = try #require(forgotten.first)
        #expect(candidate.title == "Comfortably Numb")
        #expect(candidate.reason == .forgottenFavourite(isFavourite: true, playCount: 12, listenedCount: 0))
    }

    @Test("A favourite played inside the 90-day silence window is not forgotten")
    func recentlyPlayedFavouriteIsExcluded() async throws {
        let fixture = try RediscoveryFixture()
        for id in [Int64(42), 43] {
            try fixture.track(id: id, title: "Track \(id)", addedAt: Self.settledDay)
            try fixture.state(trackId: id, isFavourite: true)
        }
        try fixture.play(trackId: 42, at: RediscoveryFixture.instant(year: 2025, month: 3, day: 10))
        // Three days before `now` — well inside the window, so 43 is still in rotation.
        try fixture.play(trackId: 43, at: Self.now - 3 * ListeningLocalTime.secondsPerDay)

        let forgotten = try await fixture.service(now: Self.now)
            .forgottenFavourites(profileId: ProfileRecord.guestID, limit: 10)

        #expect(forgotten.map(\.trackId) == [42])
    }

    @Test("An un-favourited track needs real engagement before it can be forgotten")
    func lightlyPlayedTrackIsNotEngagedWith() async throws {
        let fixture = try RediscoveryFixture()
        try fixture.track(id: 42, title: "Heavy", addedAt: Self.settledDay)
        try fixture.track(id: 43, title: "Light", addedAt: Self.settledDay)
        try fixture.state(trackId: 42, playCount: RediscoveryService.engagementThreshold)
        try fixture.state(trackId: 43, playCount: RediscoveryService.engagementThreshold - 1)

        let forgotten = try await fixture.service(now: Self.now)
            .forgottenFavourites(profileId: ProfileRecord.guestID, limit: 10)

        #expect(forgotten.map(\.trackId) == [42])
    }

    @Test("Missing and external-offline tracks never surface in any list")
    func unreachableTracksAreExcluded() async throws {
        let fixture = try RediscoveryFixture()
        try fixture.track(id: 44, title: "Gone", availability: .missing, addedAt: Self.settledDay)
        try fixture.track(id: 45, title: "Unmounted", availability: .externalOffline, addedAt: Self.settledDay)
        try fixture.track(id: 46, title: "Gone Throwback", availability: .missing, addedAt: Self.settledDay)
        try fixture.state(trackId: 44, isFavourite: true, playCount: 20)
        try fixture.play(trackId: 46, at: RediscoveryFixture.instant(year: 2025, month: 8, day: 5))

        let lists = try await fixture.service(now: Self.now).lists(profileId: ProfileRecord.guestID)

        #expect(lists == RediscoveryLists())
    }

    @Test("One profile's history never reaches another profile's lists")
    func historyIsProfileScoped() async throws {
        let fixture = try RediscoveryFixture()
        let rival = try fixture.profile("Rival")
        try fixture.track(id: 42, title: "Guest's Love", addedAt: Self.settledDay)
        try fixture.state(trackId: 42, isFavourite: true, playCount: 12)
        try fixture.play(trackId: 42, at: RediscoveryFixture.instant(year: 2025, month: 8, day: 5))
        let service = fixture.service(now: Self.now)

        let guestLists = try await service.lists(profileId: ProfileRecord.guestID)
        let rivalLists = try await service.lists(profileId: rival)

        #expect(guestLists == RediscoveryLists(forgotten: [42], throwbacks: [42]))
        // The rival owns no history at all — and has therefore never played the SAME
        // visible track, which is exactly what makes it new to them.
        #expect(rivalLists == RediscoveryLists(neverPlayed: [42]))
    }

    @Test("Never-played needs a settled, unplayed, uncounted, reachable track")
    func neverPlayedGates() async throws {
        let fixture = try RediscoveryFixture()
        let settled = Self.now - 60 * ListeningLocalTime.secondsPerDay
        try fixture.track(id: 50, title: "Settled", addedAt: settled)
        try fixture.track(id: 51, title: "Just Imported", addedAt: Self.now - 3 * ListeningLocalTime.secondsPerDay)
        try fixture.track(id: 52, title: "Has An Event", addedAt: settled)
        try fixture.track(id: 53, title: "Counted Before The Horizon", addedAt: settled)
        try fixture.track(id: 54, title: "Gone", availability: .missing, addedAt: settled)
        try fixture.track(id: 55, title: "Unknown Import Date", addedAt: nil)
        try fixture.play(trackId: 52, at: RediscoveryFixture.instant(year: 2025, month: 3))
        try fixture.state(trackId: 53, playCount: 4)

        let candidates = try await fixture.service(now: Self.now)
            .neverPlayed(profileId: ProfileRecord.guestID, limit: 10)

        #expect(candidates.map(\.trackId) == [50, 55])
        #expect(candidates.first?.reason == .neverPlayed(dateAdded: settled))
    }

    @Test("Throwbacks rank the same civil month of earlier years and honour the limit")
    func throwbackRanking() async throws {
        let fixture = try Self.makeThrowbackFixture()
        let service = fixture.service(now: Self.now)

        let ranked = try await service.throwbacks(profileId: ProfileRecord.guestID, limit: 10)
        let capped = try await service.throwbacks(profileId: ProfileRecord.guestID, limit: 1)

        #expect(ranked.map(\.trackId) == [60, 61])
        #expect(ranked.first?.reason == .throwback(yearMonth: "2025-08", plays: 3))
        #expect(ranked.last?.reason == .throwback(yearMonth: "2024-08", plays: 2))
        #expect(capped.map(\.trackId) == [60])
    }

    @Test("Every list is identical at page size 1 and at the repository ceiling")
    func pageSizeIndependence() async throws {
        let fixture = try Self.makeThrowbackFixture()
        try fixture.track(id: 70, title: "Loved", addedAt: Self.settledDay)
        try fixture.track(id: 71, title: "Untouched", addedAt: Self.settledDay)
        try fixture.state(trackId: 70, isFavourite: true, playCount: 9)
        let guest = ProfileRecord.guestID

        let narrow = fixture.service(now: Self.now, pageSize: 1)
        let wide = fixture.service(now: Self.now, pageSize: PlayEventRepository.fetchLimit)

        let narrowForgotten = try await narrow.forgottenFavourites(profileId: guest, limit: 10)
        let narrowNever = try await narrow.neverPlayed(profileId: guest, limit: 10)
        let narrowThrowbacks = try await narrow.throwbacks(profileId: guest, limit: 10)
        let wideForgotten = try await wide.forgottenFavourites(profileId: guest, limit: 10)
        let wideNever = try await wide.neverPlayed(profileId: guest, limit: 10)
        let wideThrowbacks = try await wide.throwbacks(profileId: guest, limit: 10)

        #expect(narrowForgotten == wideForgotten)
        #expect(narrowNever == wideNever)
        #expect(narrowThrowbacks == wideThrowbacks)
        #expect(narrowNever.map(\.trackId) == [71])
    }

    @Test("A fresh profile over an empty library yields three empty lists and never throws")
    func freshProfileIsEmpty() async throws {
        let fixture = try RediscoveryFixture()
        let fresh = try fixture.profile("Fresh")
        let service = fixture.service(now: Self.now)

        let freshLists = try await service.lists(profileId: fresh)
        let guestLists = try await service.lists(profileId: ProfileRecord.guestID)

        #expect(freshLists == RediscoveryLists())
        #expect(guestLists == RediscoveryLists())
    }
}

// MARK: - Fixture

private extension RediscoveryServiceTests {
    /// Track 60 played three times in August 2025; track 61 once in each of August
    /// 2025 and August 2024; track 62 five times in July 2025 — the wrong month.
    static func makeThrowbackFixture() throws -> RediscoveryFixture {
        let fixture = try RediscoveryFixture()
        for id in [Int64(60), 61, 62] {
            try fixture.track(id: id, title: "Track \(id)", addedAt: settledDay)
        }
        for day in [5, 6, 7] {
            try fixture.play(trackId: 60, at: RediscoveryFixture.instant(year: 2025, month: 8, day: day))
        }
        try fixture.play(trackId: 61, at: RediscoveryFixture.instant(year: 2025, month: 8, day: 9))
        try fixture.play(trackId: 61, at: RediscoveryFixture.instant(year: 2024, month: 8, day: 9))
        for day in [1, 2, 3, 4, 5] {
            try fixture.play(trackId: 62, at: RediscoveryFixture.instant(year: 2025, month: 7, day: day))
        }
        return fixture
    }
}

/// All three rediscovery lists as bare id arrays — the shape most assertions want.
private struct RediscoveryLists: Equatable {
    var forgotten: [Int64] = []
    var neverPlayed: [Int64] = []
    var throwbacks: [Int64] = []
}

private extension RediscoveryProviding {
    func lists(profileId: Int64, limit: Int = 10) async throws -> RediscoveryLists {
        try await RediscoveryLists(
            forgotten: forgottenFavourites(profileId: profileId, limit: limit).map(\.trackId),
            neverPlayed: neverPlayed(profileId: profileId, limit: limit).map(\.trackId),
            throwbacks: throwbacks(profileId: profileId, limit: limit).map(\.trackId)
        )
    }
}

/// A migrated in-memory database plus the seeding vocabulary the suite writes in.
private struct RediscoveryFixture {
    let appDB: AppDatabase

    init() throws {
        appDB = try AppDatabase.makeEmpty()
    }

    /// A UTC instant named by its civil date, through the same helper the service
    /// buckets months with.
    static func instant(year: Int, month: Int, day: Int = 1, hour: Int = 0) -> TimeInterval {
        CivilMonth.startOfMonthEpochSeconds(year: year, month: month)
            + Double(day - 1) * ListeningLocalTime.secondsPerDay
            + Double(hour) * ListeningLocalTime.secondsPerHour
    }

    /// Inserts a track at an EXPLICIT rowid so the fixtures can name the plan's
    /// `trackId: 42` directly instead of counting inserts.
    func track(id: Int64, title: String, availability: Availability = .present, addedAt: TimeInterval?) throws {
        var record = TrackRecord(
            id: id,
            filePath: "/Music/\(id).flac",
            title: title,
            artistName: "Pink Floyd",
            availability: availability,
            dateAdded: addedAt
        )
        try appDB.writer.write { db in try record.insert(db) }
    }

    func profile(_ name: String) throws -> Int64 {
        let created = try ProfileRepository(appDB).create(ProfileRecord(name: name))
        return try #require(created.id)
    }

    func play(profileId: Int64 = ProfileRecord.guestID, trackId: Int64, at startedAt: TimeInterval) throws {
        var event = PlayEventRecord(
            profileId: profileId,
            trackId: trackId,
            artistName: "Pink Floyd",
            title: "Track \(trackId)",
            durationSeconds: 300,
            startedAt: startedAt,
            utcOffsetSeconds: 0,
            secondsListened: 280
        )
        try appDB.writer.write { db in try event.insert(db) }
    }

    /// Writes the profile's sparse `profileTrackState` row. Engagement is read from
    /// this table only — never from the frozen `track` user-state columns.
    func state(
        profileId: Int64 = ProfileRecord.guestID,
        trackId: Int64,
        isFavourite: Bool = false,
        playCount: Int = 0,
        listenedCount: Int = 0
    ) throws {
        try appDB.writer.write { db in
            try db.execute(sql: """
            INSERT INTO profileTrackState (profileId, trackId, isFavourite, playCount, listenedCount)
            VALUES (?, ?, ?, ?, ?)
            """, arguments: [profileId, trackId, isFavourite, playCount, listenedCount])
        }
    }

    func service(now: TimeInterval, pageSize: Int = PlayEventRepository.fetchLimit) -> RediscoveryService {
        RediscoveryService(appDB, now: { Date(timeIntervalSince1970: now) }, pageSize: pageSize)
    }
}
