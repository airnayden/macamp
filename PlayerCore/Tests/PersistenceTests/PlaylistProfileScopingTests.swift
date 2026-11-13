import Foundation
import GRDB
import Persistence
import Testing

@Suite("PlaylistProfileScopingTests")
struct PlaylistProfileScopingTests {
    private struct Fixture {
        let playlistRepo: PlaylistRepository
        let profileTwoId: Int64
    }

    /// Seeds Guest (`1`) + a second profile, one playlist owned by each.
    private func makeFixture() throws -> Fixture {
        let appDB = try AppDatabase.makeEmpty()
        let profileRepo = ProfileRepository(appDB)
        let playlistRepo = PlaylistRepository(appDB)
        let profileTwo = try profileRepo.create(ProfileRecord(name: "Two"))
        let profileTwoId = try #require(profileTwo.id)
        try playlistRepo.create(named: "Guest Mix", profileId: ProfileRecord.guestID)
        try playlistRepo.create(named: "Two Mix", profileId: profileTwoId)
        return Fixture(playlistRepo: playlistRepo, profileTwoId: profileTwoId)
    }

    @Test("playlistsWithTrackCounts lists only the requested profile's playlists")
    func trackCountListScopedByProfile() throws {
        let fixture = try makeFixture()

        let guestPage = try fixture.playlistRepo.playlistsWithTrackCounts(
            profileId: ProfileRecord.guestID,
            after: nil,
            limit: 100
        )
        let twoPage = try fixture.playlistRepo.playlistsWithTrackCounts(
            profileId: fixture.profileTwoId,
            after: nil,
            limit: 100
        )

        #expect(guestPage.items.map(\.playlist.name) == ["Guest Mix"])
        #expect(twoPage.items.map(\.playlist.name) == ["Two Mix"])
        // Profile 2 sees ZERO of profile 1's (Guest's) playlists, and vice versa.
        #expect(!twoPage.items.contains { $0.playlist.name == "Guest Mix" })
        #expect(!guestPage.items.contains { $0.playlist.name == "Two Mix" })
    }

    @Test("playlistsPage lists only the requested profile's playlists")
    func plainPageScopedByProfile() throws {
        let fixture = try makeFixture()

        let guestPage = try fixture.playlistRepo.playlistsPage(
            profileId: ProfileRecord.guestID,
            after: nil,
            limit: 100
        )
        let twoPage = try fixture.playlistRepo.playlistsPage(
            profileId: fixture.profileTwoId,
            after: nil,
            limit: 100
        )

        #expect(guestPage.items.map(\.name) == ["Guest Mix"])
        #expect(twoPage.items.map(\.name) == ["Two Mix"])
    }

    @Test("create stamps the owning profile onto the new playlist row")
    func createStampsProfileId() throws {
        let fixture = try makeFixture()
        let created = try fixture.playlistRepo.create(named: "Fresh", profileId: fixture.profileTwoId)
        let identifier = try #require(created.id)
        let fetched = try #require(try fixture.playlistRepo.fetchPlaylist(id: identifier))
        #expect(fetched.profileId == fixture.profileTwoId)
    }
}
