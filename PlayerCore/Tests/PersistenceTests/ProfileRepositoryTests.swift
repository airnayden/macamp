import Foundation
import GRDB
import Persistence
import Testing

@Suite("ProfileRepositoryTests")
struct ProfileRepositoryTests {
    @Test("create then fetch round-trips a profile")
    func createRoundTrip() throws {
        let appDB = try AppDatabase.makeEmpty()
        let repo = ProfileRepository(appDB)
        let created = try repo.create(
            ProfileRecord(name: "Ada", lastName: "Lovelace", bio: "Analyst")
        )
        let createdID = try #require(created.id)
        let fetched = try #require(try repo.profile(id: createdID))
        #expect(fetched.name == "Ada")
        #expect(fetched.lastName == "Lovelace")
        #expect(fetched.bio == "Analyst")
        #expect(fetched.avatarId == ProfileRecord.defaultAvatarID)
        #expect(fetched.pinHash == nil)
    }

    @Test("allProfiles returns Guest first, then every profile, capped")
    func allProfilesOrdered() throws {
        let appDB = try AppDatabase.makeEmpty()
        let repo = ProfileRepository(appDB)
        try repo.create(ProfileRecord(name: "Zoe"))
        try repo.create(ProfileRecord(name: "Ada"))
        let all = try repo.allProfiles(limit: ProfileRepository.fetchLimit)
        #expect(all.count == 3) // Guest + 2
        #expect(all.first?.id == ProfileRecord.guestID)
        #expect(all.first?.name == "Guest")
    }

    @Test("update persists changed fields")
    func updatePersists() throws {
        let appDB = try AppDatabase.makeEmpty()
        let repo = ProfileRepository(appDB)
        var created = try repo.create(ProfileRecord(name: "Ada"))
        created.name = "Ada L."
        created.bio = "Mathematician"
        created.avatarId = "waveform-neon"
        try repo.update(created)
        let createdID = try #require(created.id)
        let fetched = try #require(try repo.profile(id: createdID))
        #expect(fetched.name == "Ada L.")
        #expect(fetched.bio == "Mathematician")
        #expect(fetched.avatarId == "waveform-neon")
    }

    @Test("delete(id: guestID) throws guestUndeletable and Guest survives")
    func deleteGuestThrows() throws {
        let appDB = try AppDatabase.makeEmpty()
        let repo = ProfileRepository(appDB)
        #expect(throws: ProfileRepositoryError.guestUndeletable) {
            try repo.delete(id: ProfileRecord.guestID)
        }
        #expect(try repo.profile(id: ProfileRecord.guestID) != nil)
    }

    @Test("deleting a profile cascades its trackState, playlist and libraryRoot rows")
    func deleteCascades() throws {
        // MUST use makeEmpty() — GRDB enables foreign keys by default, so the CASCADE
        // actually fires. A bare, unconfigured queue would leave FKs OFF and these
        // count-zero assertions would pass even with cascades broken.
        let appDB = try AppDatabase.makeEmpty()
        let repo = ProfileRepository(appDB)
        let rootRepo = LibraryRootRepository(appDB)

        let profile = try repo.create(ProfileRecord(name: "Ada"))
        let profileID = try #require(profile.id)

        try appDB.writer.write { db in
            var track = TrackRecord(filePath: "/music/a.flac")
            try track.insert(db)
            let trackID = try #require(track.id)
            let state = ProfileTrackStateRecord(
                profileId: profileID,
                trackId: trackID,
                isFavourite: true,
                playCount: 3,
                listenedCount: 1,
                customPosition: 7
            )
            try state.insert(db)
            // PlaylistRecord has no `profileId` property (not modified by this task),
            // so scope the playlist to the profile via raw SQL.
            try db.execute(
                sql: "INSERT INTO playlist (name, isSmartPlaylist, profileId) VALUES (?, 0, ?)",
                arguments: ["Ada's mix", profileID]
            )
        }
        try rootRepo.addRoot(profileId: profileID, path: "/music")

        // Sanity: the dependent rows exist before the delete.
        try appDB.writer.read { db in
            try #expect(ProfileTrackStateRecord.fetchCount(db) == 1)
            try #expect(LibraryRootRecord.fetchCount(db) == 1)
            let playlists = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM playlist WHERE profileId = ?",
                arguments: [profileID]
            )
            #expect(playlists == 1)
        }

        try repo.delete(id: profileID)

        try appDB.writer.read { db in
            // Read the profile via `db` directly — calling `repo.profile(id:)` here
            // would open a nested `writer.read`, which GRDB forbids (not reentrant).
            try #expect(ProfileRecord.fetchOne(db, key: profileID) == nil)
            try #expect(ProfileTrackStateRecord.fetchCount(db) == 0)
            try #expect(LibraryRootRecord.fetchCount(db) == 0)
            let playlists = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM playlist WHERE profileId = ?",
                arguments: [profileID]
            )
            #expect(playlists == 0)
            // The track is NOT owned by the profile — it survives.
            try #expect(TrackRecord.fetchCount(db) == 1)
        }
    }
}
