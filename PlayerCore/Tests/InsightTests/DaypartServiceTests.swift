import Foundation
import GRDB
import Persistence
import Services
import Testing

/// ``DaypartService`` over scripted v15 fixtures with an injected clock and zone.
///
/// The whole point of the type is that a play's bucket comes from the offset STORED
/// on the event, so the fixtures deliberately seed one UTC instant under two
/// different offsets and expect two different dayparts.
@Suite("DaypartServiceTests")
struct DaypartServiceTests {
    /// The reference instant the history window is measured back from.
    private static let now = DaypartFixture.instant(year: 2026, month: 8, day: 15, hour: 12)

    @Test("Local hours map onto the four buckets, with night wrapping midnight")
    func hourBuckets() {
        #expect((0 ... 4).allSatisfy { Daypart.containing(localHour: $0) == .night })
        #expect((5 ... 11).allSatisfy { Daypart.containing(localHour: $0) == .morning })
        #expect((12 ... 16).allSatisfy { Daypart.containing(localHour: $0) == .afternoon })
        #expect((17 ... 21).allSatisfy { Daypart.containing(localHour: $0) == .evening })
        #expect((22 ... 23).allSatisfy { Daypart.containing(localHour: $0) == .night })
    }

    @Test("The bucket follows the offset stored on the event, never UTC")
    func bucketingUsesTheStoredOffset() async throws {
        let fixture = try DaypartFixture()
        try fixture.track(id: 10)
        try fixture.track(id: 11)
        let instant = DaypartFixture.instant(year: 2026, month: 8, day: 1, hour: 3)
        try fixture.play(trackId: 10, at: instant, utcOffsetSeconds: 0)
        try fixture.play(trackId: 11, at: instant, utcOffsetSeconds: 9 * 3600)

        let ranked = try await fixture.service(now: Self.now)
            .topTracksByDaypart(profileId: ProfileRecord.guestID, limit: 10)

        #expect(ranked[.night]?.map(\.trackId) == [10])
        #expect(ranked[.afternoon]?.map(\.trackId) == [11])
        #expect(ranked[.morning] == nil)
        #expect(ranked[.evening] == nil)
    }

    @Test("Within a bucket, more plays rank first and ties break on the lower id")
    func rankingIsTotal() async throws {
        let fixture = try DaypartFixture()
        for id in [Int64(20), 21, 22] {
            try fixture.track(id: id)
        }
        try fixture.playMorning(trackId: 20, days: [1, 2, 3])
        try fixture.playMorning(trackId: 21, days: [4])
        try fixture.playMorning(trackId: 22, days: [5, 6, 7])

        let ranked = try await fixture.service(now: Self.now)
            .topTracksByDaypart(profileId: ProfileRecord.guestID, limit: 10)
        let morning = try #require(ranked[.morning])

        #expect(morning.map(\.trackId) == [20, 22, 21])
        #expect(morning.map(\.plays) == [3, 3, 1])
        #expect(morning.allSatisfy { $0.daypart == .morning })
    }

    @Test("Missing and external-offline tracks never enter a daypart list")
    func unreachableTracksAreExcluded() async throws {
        let fixture = try DaypartFixture()
        try fixture.track(id: 23, availability: .missing)
        try fixture.track(id: 24, availability: .externalOffline)
        try fixture.playMorning(trackId: 23, days: [1, 2, 3, 4, 5])
        try fixture.playMorning(trackId: 24, days: [6])

        let ranked = try await fixture.service(now: Self.now)
            .topTracksByDaypart(profileId: ProfileRecord.guestID, limit: 10)

        #expect(ranked.isEmpty)
    }

    @Test("One profile's plays never reach another profile's dayparts")
    func historyIsProfileScoped() async throws {
        let fixture = try DaypartFixture()
        let rival = try fixture.profile("Rival")
        try fixture.track(id: 30)
        try fixture.track(id: 31)
        try fixture.playMorning(trackId: 30, days: [1, 2])
        try fixture.playMorning(profileId: rival, trackId: 31, days: [3])
        let service = fixture.service(now: Self.now)

        let guest = try await service.topTracksByDaypart(profileId: ProfileRecord.guestID, limit: 10)
        let rivals = try await service.topTracksByDaypart(profileId: rival, limit: 10)

        #expect(guest[.morning]?.map(\.trackId) == [30])
        #expect(rivals[.morning]?.map(\.trackId) == [31])
    }

    @Test("Plays older than the history window are ignored")
    func historyWindowIsBounded() async throws {
        let fixture = try DaypartFixture()
        try fixture.track(id: 40)
        try fixture.track(id: 41)
        let day = ListeningLocalTime.secondsPerDay
        // Local hour 8 on both, so only their age can separate them.
        try fixture.play(trackId: 40, at: Self.now - 100 * day - 4 * ListeningLocalTime.secondsPerHour)
        try fixture.play(trackId: 41, at: Self.now - 400 * day - 4 * ListeningLocalTime.secondsPerHour)

        let ranked = try await fixture.service(now: Self.now)
            .topTracksByDaypart(profileId: ProfileRecord.guestID, limit: 10)

        #expect(ranked[.morning]?.map(\.trackId) == [40])
        #expect(ranked.values.flatMap(\.self).map(\.trackId) == [40])
    }

    @Test("The single-bucket read agrees with the whole-day read, and honours the limit")
    func singleBucketMatchesTheWholeDay() async throws {
        let fixture = try DaypartFixture()
        for id in [Int64(50), 51] {
            try fixture.track(id: id)
        }
        try fixture.playMorning(trackId: 50, days: [1, 2])
        try fixture.playMorning(trackId: 51, days: [3])
        let service = fixture.service(now: Self.now)
        let guest = ProfileRecord.guestID

        let whole = try await service.topTracksByDaypart(profileId: guest, limit: 10)
        let single = try await service.topTracks(profileId: guest, daypart: .morning, limit: 10)
        let capped = try await service.topTracks(profileId: guest, daypart: .morning, limit: 1)
        let empty = try await service.topTracks(profileId: guest, daypart: .evening, limit: 10)

        #expect(single == whole[.morning])
        #expect(capped.map(\.trackId) == [50])
        #expect(empty.isEmpty)
    }

    @Test("Rankings are identical at page size 1 and at the repository ceiling")
    func pageSizeIndependence() async throws {
        let fixture = try DaypartFixture()
        for id in [Int64(60), 61, 62] {
            try fixture.track(id: id)
        }
        try fixture.playMorning(trackId: 60, days: [1, 2, 3])
        try fixture.playMorning(trackId: 61, days: [4, 5])
        try fixture.play(trackId: 62, at: DaypartFixture.instant(year: 2026, month: 8, day: 2, hour: 19))
        let guest = ProfileRecord.guestID

        let narrow = try await fixture.service(now: Self.now, pageSize: 1)
            .topTracksByDaypart(profileId: guest, limit: 10)
        let wide = try await fixture.service(now: Self.now, pageSize: PlayEventRepository.fetchLimit)
            .topTracksByDaypart(profileId: guest, limit: 10)

        #expect(narrow == wide)
        #expect(narrow[.morning]?.map(\.trackId) == [60, 61])
        #expect(narrow[.evening]?.map(\.trackId) == [62])
    }

    @Test("The current daypart reads the injected zone's offset, not the machine's")
    func currentDaypartUsesTheInjectedZone() throws {
        let fixture = try DaypartFixture()
        let instant = DaypartFixture.instant(year: 2026, month: 8, day: 15, hour: 3)
        let tokyo = try #require(TimeZone(secondsFromGMT: 9 * 3600))
        let honolulu = try #require(TimeZone(secondsFromGMT: -10 * 3600))

        #expect(fixture.service(now: instant, timeZone: .gmt).currentDaypart() == .night)
        #expect(fixture.service(now: instant, timeZone: tokyo).currentDaypart() == .afternoon)
        #expect(fixture.service(now: instant, timeZone: honolulu).currentDaypart() == .evening)
    }

    @Test("A fresh profile over an empty library yields no dayparts and never throws")
    func freshProfileIsEmpty() async throws {
        let fixture = try DaypartFixture()
        let fresh = try fixture.profile("Fresh")
        let service = DaypartService(fixture.appDB, now: { Date(timeIntervalSince1970: Self.now) })

        let freshDayparts = try await service.topTracksByDaypart(profileId: fresh, limit: 10)
        let guestDayparts = try await service.topTracksByDaypart(profileId: ProfileRecord.guestID, limit: 10)
        let freshMorning = try await service.topTracks(profileId: fresh, daypart: .morning, limit: 10)

        #expect(freshDayparts.isEmpty)
        #expect(guestDayparts.isEmpty)
        #expect(freshMorning.isEmpty)
    }
}

// MARK: - Fixture

/// A migrated in-memory database plus the seeding vocabulary the suite writes in.
private struct DaypartFixture {
    let appDB: AppDatabase

    init() throws {
        appDB = try AppDatabase.makeEmpty()
    }

    /// A UTC instant named by its civil date and hour.
    static func instant(year: Int, month: Int, day: Int = 1, hour: Int = 0) -> TimeInterval {
        CivilMonth.startOfMonthEpochSeconds(year: year, month: month)
            + Double(day - 1) * ListeningLocalTime.secondsPerDay
            + Double(hour) * ListeningLocalTime.secondsPerHour
    }

    func track(id: Int64, availability: Availability = .present) throws {
        var record = TrackRecord(
            id: id,
            filePath: "/Music/\(id).flac",
            title: "Track \(id)",
            artistName: "Pink Floyd",
            availability: availability
        )
        try appDB.writer.write { db in try record.insert(db) }
    }

    func profile(_ name: String) throws -> Int64 {
        let created = try ProfileRepository(appDB).create(ProfileRecord(name: name))
        return try #require(created.id)
    }

    func play(
        profileId: Int64 = ProfileRecord.guestID,
        trackId: Int64,
        at startedAt: TimeInterval,
        utcOffsetSeconds: Int = 0
    ) throws {
        var event = PlayEventRecord(
            profileId: profileId,
            trackId: trackId,
            artistName: "Pink Floyd",
            title: "Track \(trackId)",
            durationSeconds: 300,
            startedAt: startedAt,
            utcOffsetSeconds: utcOffsetSeconds,
            secondsListened: 280
        )
        try appDB.writer.write { db in try event.insert(db) }
    }

    /// One play at local hour 8 on each of the given days of August 2026.
    func playMorning(profileId: Int64 = ProfileRecord.guestID, trackId: Int64, days: [Int]) throws {
        for day in days {
            try play(
                profileId: profileId,
                trackId: trackId,
                at: Self.instant(year: 2026, month: 8, day: day, hour: 8)
            )
        }
    }

    func service(
        now: TimeInterval,
        timeZone: TimeZone = .gmt,
        pageSize: Int = PlayEventRepository.fetchLimit
    ) -> DaypartService {
        DaypartService(
            events: PlayEventRepository(appDB),
            tracks: TrackRepository(appDB),
            now: { Date(timeIntervalSince1970: now) },
            timeZone: timeZone,
            pageSize: pageSize
        )
    }
}
