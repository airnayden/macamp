import Foundation
import GRDB
import Persistence
import Testing

/// Correctness for the bounded batch resolver ``TrackRepository/resolvedTracks(profileId:trackIds:)``
/// (Todo 2): id-keyed resolution, `LEFT JOIN … COALESCE` defaults for a track the
/// profile holds no state row for, the empty-input short circuit, and the 500-id
/// bound. All run on `AppDatabase.makeEmpty()`.
@Suite("ResolvedTracksBatchTests")
struct ResolvedTracksBatchTests {
    private struct Harness {
        let database: AppDatabase
        let tracks: TrackRepository
        let profiles: ProfileRepository
    }

    private func makeHarness() throws -> Harness {
        let database = try AppDatabase.makeEmpty()
        return Harness(
            database: database,
            tracks: TrackRepository(database),
            profiles: ProfileRepository(database)
        )
    }

    @discardableResult
    private func seedTrack(
        _ tracks: TrackRepository,
        path: String,
        title: String,
        availability: Availability = .present
    ) throws -> Int64 {
        let record = try tracks.insert(TrackRecord(
            filePath: path,
            title: title,
            availability: availability
        ))
        return try #require(record.id)
    }

    private func makeProfile(_ profiles: ProfileRepository, name: String) throws -> Int64 {
        let created = try profiles.create(ProfileRecord(name: name))
        return try #require(created.id)
    }

    private func seedTracks(_ harness: Harness, count: Int) throws -> [Int64] {
        var seeded: [Int64] = []
        seeded.reserveCapacity(count)
        for index in 0 ..< count {
            let trackId = try seedTrack(
                harness.tracks, path: "/Music/\(index).flac", title: "Track \(index)"
            )
            seeded.append(trackId)
        }
        return seeded
    }

    @Test("mixed ids resolve only the existing tracks, keyed by id, with this profile's state")
    func mixedIdsResolveOnlyExistingTracks() async throws {
        let harness = try makeHarness()
        let rival = try makeProfile(harness.profiles, name: "Rival")
        let favedID = try seedTrack(harness.tracks, path: "/Music/a.flac", title: "Alpha")
        let playedID = try seedTrack(harness.tracks, path: "/Music/b.flac", title: "Bravo")
        let absentID = playedID + 1000

        try await harness.tracks.setFavourite(
            profileId: ProfileRecord.guestID, trackId: favedID, isFavourite: true
        )
        try await harness.tracks.incrementPlayCount(profileId: ProfileRecord.guestID, trackId: playedID)
        try await harness.tracks.incrementPlayCount(profileId: ProfileRecord.guestID, trackId: playedID)
        try await harness.tracks.setFavourite(profileId: rival, trackId: playedID, isFavourite: true)

        let resolved = try await harness.tracks.resolvedTracks(
            profileId: ProfileRecord.guestID,
            trackIds: [favedID, favedID, playedID, absentID]
        )

        #expect(resolved.count == 2)
        #expect(resolved[absentID] == nil)
        let faved = try #require(resolved[favedID])
        #expect(faved.track.title == "Alpha")
        #expect(faved.isFavourite)
        #expect(faved.playCount == 0)
        let played = try #require(resolved[playedID])
        #expect(played.track.title == "Bravo")
        #expect(played.playCount == 2)
        #expect(played.isFavourite == false) // The rival's favourite never leaks into Guest.
    }

    @Test("a track with no profileTrackState row still resolves to the COALESCE defaults")
    func trackWithoutProfileStateResolvesToDefaults() async throws {
        let harness = try makeHarness()
        let untouchedID = try seedTrack(harness.tracks, path: "/Music/untouched.flac", title: "Untouched")

        let stateRows = try await harness.database.writer.read { db in
            try ProfileTrackStateRecord.fetchCount(db)
        }
        #expect(stateRows == 0)

        let resolved = try await harness.tracks.resolvedTracks(
            profileId: ProfileRecord.guestID, trackIds: [untouchedID]
        )

        let row = try #require(resolved[untouchedID])
        #expect(row.track.title == "Untouched")
        #expect(row.isFavourite == false)
        #expect(row.playCount == 0)
        #expect(row.listenedCount == 0)
        #expect(row.customPosition == nil)
    }

    @Test("empty input returns an empty map without touching the database")
    func emptyInputReturnsEmptyWithoutTouchingDatabase() async throws {
        // A schema-less writer: any statement against `track` throws. An empty input
        // still succeeding therefore proves the short circuit runs BEFORE the read,
        // and the non-empty control proves this harness would have caught a query.
        let schemaless = try DatabaseQueue()
        let repo = TrackRepository(schemaless)

        let resolved = try await repo.resolvedTracks(profileId: ProfileRecord.guestID, trackIds: [])
        #expect(resolved.isEmpty)

        await #expect(throws: DatabaseError.self) {
            _ = try await repo.resolvedTracks(profileId: ProfileRecord.guestID, trackIds: [1])
        }
    }

    @Test("150 ids all resolve — they sit under the bound the proposal ceiling raised it to")
    func oneHundredFiftyIdsAllResolve() async throws {
        let harness = try makeHarness()
        let seeded = try seedTracks(harness, count: 150)

        let resolved = try await harness.tracks.resolvedTracks(
            profileId: ProfileRecord.guestID, trackIds: seeded
        )

        #expect(resolved.count == 150)
        let everyKeyWasRequested = resolved.keys.allSatisfy(Set(seeded).contains)
        #expect(everyKeyWasRequested)
    }

    @Test("more than 500 ids truncate to the bound without error")
    func moreThanFiveHundredIdsTruncateWithoutError() async throws {
        let harness = try makeHarness()
        let seeded = try seedTracks(harness, count: 501)

        let resolved = try await harness.tracks.resolvedTracks(
            profileId: ProfileRecord.guestID, trackIds: seeded
        )

        #expect(resolved.count == 500)
        let everyKeyWasRequested = resolved.keys.allSatisfy(Set(seeded).contains)
        #expect(everyKeyWasRequested)
    }

    @Test("history resolves an unavailable track — no availability or visibility filtering")
    func unavailableTrackStillResolves() async throws {
        let harness = try makeHarness()
        let scoped = try makeProfile(harness.profiles, name: "Scoped")
        try LibraryRootRepository(harness.database).addRoot(profileId: scoped, path: "/Music/Scoped")
        let missingID = try seedTrack(
            harness.tracks, path: "/Elsewhere/gone.flac", title: "Gone", availability: .missing
        )

        let resolved = try await harness.tracks.resolvedTracks(profileId: scoped, trackIds: [missingID])

        let row = try #require(resolved[missingID])
        #expect(row.track.title == "Gone")
        #expect(row.track.availability == .missing)
    }
}
