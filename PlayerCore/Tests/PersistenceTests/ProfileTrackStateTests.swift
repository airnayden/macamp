import Foundation
import GRDB
import Persistence
import Testing

/// Isolation + correctness for the profile-scoped state APIs on ``TrackRepository``
/// (Task 6): favourites, play/listen counters and custom order routed through the
/// sparse `profileTrackState` table via single-statement UPSERTs and
/// profile-resolved reads. All run on `AppDatabase.makeEmpty()` (foreign keys ON).
@Suite("ProfileTrackStateTests")
struct ProfileTrackStateTests {
    private func seedTrack(_ appDB: AppDatabase, path: String) throws -> Int64 {
        var track = TrackRecord(filePath: path)
        try appDB.writer.write { db in try track.insert(db) }
        return try #require(track.id)
    }

    private func fetchState(_ appDB: AppDatabase, profileId: Int64, trackId: Int64) throws -> ProfileTrackStateRecord? {
        try appDB.writer.read { db in
            try ProfileTrackStateRecord.fetchOne(db, key: ["profileId": profileId, "trackId": trackId])
        }
    }

    private func stateRowCount(_ appDB: AppDatabase) throws -> Int {
        try appDB.writer.read { db in try ProfileTrackStateRecord.fetchCount(db) }
    }

    @Test("toggling favourite for profile 2 leaves profile 1's row byte-identical")
    func crossProfileIsolation() async throws {
        let appDB = try AppDatabase.makeEmpty()
        let repo = TrackRepository(appDB)
        let profile2 = try ProfileRepository(appDB).create(ProfileRecord(name: "P2"))
        let profile2ID = try #require(profile2.id)
        let trackId = try seedTrack(appDB, path: "/music/a.flac")

        try await repo.setFavourite(profileId: ProfileRecord.guestID, trackId: trackId, isFavourite: true)
        try await repo.incrementPlayCount(profileId: ProfileRecord.guestID, trackId: trackId)
        let before = try #require(try fetchState(appDB, profileId: ProfileRecord.guestID, trackId: trackId))

        _ = try await repo.toggleFavourite(profileId: profile2ID, trackId: trackId)

        let after = try #require(try fetchState(appDB, profileId: ProfileRecord.guestID, trackId: trackId))
        #expect(after == before) // Guest's row is byte-for-byte unchanged.

        let profile2Row = try #require(try fetchState(appDB, profileId: profile2ID, trackId: trackId))
        #expect(profile2Row.isFavourite == true)
        #expect(profile2Row.playCount == 0) // profile 2 never played it.
    }

    @Test("UPSERT creates the sparse row on first favourite of an untouched track")
    func upsertCreatesSparseRow() async throws {
        let appDB = try AppDatabase.makeEmpty()
        let repo = TrackRepository(appDB)
        let trackId = try seedTrack(appDB, path: "/music/b.flac")

        let countBefore = try stateRowCount(appDB)
        #expect(countBefore == 0) // Sparse: no rows until first write.

        let newValue = try await repo.toggleFavourite(profileId: ProfileRecord.guestID, trackId: trackId)
        #expect(newValue == true)

        let row = try #require(try fetchState(appDB, profileId: ProfileRecord.guestID, trackId: trackId))
        #expect(row.isFavourite == true)
        #expect(row.playCount == 0)
        #expect(row.listenedCount == 0)
        #expect(row.customPosition == nil)
        let countAfter = try stateRowCount(appDB)
        #expect(countAfter == 1)
    }

    @Test("favouriteTracks(profileId:) returns only that profile's favourites")
    func favouriteTracksScoped() async throws {
        let appDB = try AppDatabase.makeEmpty()
        let repo = TrackRepository(appDB)
        let profile2 = try ProfileRepository(appDB).create(ProfileRecord(name: "P2"))
        let profile2ID = try #require(profile2.id)
        let id1 = try seedTrack(appDB, path: "/music/1.flac")
        let id2 = try seedTrack(appDB, path: "/music/2.flac")

        try await repo.setFavourite(profileId: ProfileRecord.guestID, trackId: id1, isFavourite: true)
        try await repo.setFavourite(profileId: profile2ID, trackId: id2, isFavourite: true)

        let guestFavourites = try repo.favouriteTracks(profileId: ProfileRecord.guestID)
        let profile2Favourites = try repo.favouriteTracks(profileId: profile2ID)
        #expect(guestFavourites.map(\.track.id) == [id1])
        #expect(profile2Favourites.map(\.track.id) == [id2])
        let everyGuestFavouriteResolvesTrue = guestFavourites.allSatisfy(\.isFavourite)
        #expect(everyGuestFavouriteResolvesTrue)

        let backwardCompatible = try repo.favouriteTracks() // Guest-defaulted [TrackRecord] overload.
        #expect(backwardCompatible.map(\.id) == [id1])
    }

    @Test("topPlayedTracks and totalPlayCount are scoped per profile")
    func statsScopedPerProfile() async throws {
        let appDB = try AppDatabase.makeEmpty()
        let repo = TrackRepository(appDB)
        let profile2 = try ProfileRepository(appDB).create(ProfileRecord(name: "P2"))
        let profile2ID = try #require(profile2.id)
        let id1 = try seedTrack(appDB, path: "/music/1.flac")
        let id2 = try seedTrack(appDB, path: "/music/2.flac")

        for _ in 0 ..< 3 {
            try await repo.incrementPlayCount(profileId: ProfileRecord.guestID, trackId: id1)
        }
        try await repo.incrementPlayCount(profileId: ProfileRecord.guestID, trackId: id2)
        for _ in 0 ..< 2 {
            try await repo.incrementPlayCount(profileId: profile2ID, trackId: id2)
        }

        #expect(try await repo.totalPlayCount(profileId: ProfileRecord.guestID) == 4)
        #expect(try await repo.totalPlayCount(profileId: profile2ID) == 2)

        let guestTop = try await repo.topPlayedTracks(profileId: ProfileRecord.guestID, limit: 10)
        #expect(guestTop.map(\.track.id) == [id1, id2]) // playCount DESC: t1(3), t2(1)
        #expect(guestTop.map(\.playCount) == [3, 1])

        let profile2Top = try await repo.topPlayedTracks(profileId: profile2ID, limit: 10)
        #expect(profile2Top.map(\.track.id) == [id2])
        #expect(profile2Top.first?.playCount == 2)

        #expect(try await repo.totalPlayCount() == 4) // Guest-defaulted overload.
        #expect(try await repo.topPlayedTracks(limit: 10).map(\.id) == [id1, id2])
    }

    @Test("resolvedTrack resolves to 0/false when the profile has no state row")
    func resolvedTrackCoalescesDefaults() throws {
        let appDB = try AppDatabase.makeEmpty()
        let repo = TrackRepository(appDB)
        let trackId = try seedTrack(appDB, path: "/music/y.flac")

        let resolved = try #require(try repo.resolvedTrack(profileId: ProfileRecord.guestID, trackId: trackId))
        #expect(resolved.track.id == trackId)
        #expect(resolved.isFavourite == false)
        #expect(resolved.playCount == 0)
        #expect(resolved.listenedCount == 0)
        #expect(resolved.customPosition == nil)
    }

    @Test("updateCustomPositions and incrementListenedCount UPSERT per profile")
    func customPositionsAndListenUpsert() async throws {
        let appDB = try AppDatabase.makeEmpty()
        let repo = TrackRepository(appDB)
        let id1 = try seedTrack(appDB, path: "/music/1.flac")
        let id2 = try seedTrack(appDB, path: "/music/2.flac")

        try await repo.updateCustomPositions(
            profileId: ProfileRecord.guestID,
            [(trackId: id1, position: 0), (trackId: id2, position: 1)]
        )
        try await repo.incrementListenedCount(profileId: ProfileRecord.guestID, trackId: id1)

        let resolved1 = try #require(try repo.resolvedTrack(trackId: id1))
        #expect(resolved1.customPosition == 0)
        #expect(resolved1.listenedCount == 1)
        let resolved2 = try #require(try repo.resolvedTrack(trackId: id2))
        #expect(resolved2.customPosition == 1)
        #expect(resolved2.listenedCount == 0)
    }

    @Test("a state write against a nonexistent profileId fails the foreign key")
    func nonexistentProfileFailsForeignKey() async throws {
        let appDB = try AppDatabase.makeEmpty()
        let repo = TrackRepository(appDB)
        let trackId = try seedTrack(appDB, path: "/music/x.flac")
        await #expect(throws: (any Error).self) {
            try await repo.setFavourite(profileId: 9999, trackId: trackId, isFavourite: true)
        }
    }
}
