// `PlaylistRepository.containsTrack` against real SQL, all three answers.
//
// The third answer is the one worth a test of its own: asking about a playlist that does
// not exist must be `false`, not a throw and not a crash. Its only caller is a
// download-completion callback with no error channel, and "the playlist was deleted
// while the download ran" is an ordinary thing for a listener to do.
import Foundation
import GRDB
import Persistence
import Testing

@Suite("PlaylistMembershipReadTests")
struct PlaylistMembershipReadTests {
    private struct Fixture {
        let playlists: PlaylistRepository
        let playlistId: Int64
        let memberId: Int64
        let strangerId: Int64
    }

    /// One playlist holding exactly one of the two library rows.
    private func makeFixture() throws -> Fixture {
        let appDB = try AppDatabase.makeEmpty()
        let playlists = PlaylistRepository(appDB)
        let playlist = try playlists.create(named: "Chat picks", profileId: ProfileRecord.guestID)
        let playlistId = try #require(playlist.id)
        let ids = try appDB.writer.write { db -> [Int64] in
            try ["/Music/member.flac", "/Music/stranger.flac"].map { path in
                var record = TrackRecord(filePath: path, title: "T", duration: 100)
                try record.insert(db)
                return record.id ?? 0
            }
        }
        let memberId = try #require(ids.first)
        let strangerId = try #require(ids.last)
        try playlists.addTrack(trackId: memberId, toPlaylist: playlistId)
        return Fixture(
            playlists: playlists,
            playlistId: playlistId,
            memberId: memberId,
            strangerId: strangerId
        )
    }

    @Test("a track in the playlist reads true and one outside it reads false")
    func membershipAnswersBothWays() async throws {
        let fixture = try makeFixture()

        let member = try await fixture.playlists.containsTrack(
            playlistId: fixture.playlistId,
            trackId: fixture.memberId
        )
        let stranger = try await fixture.playlists.containsTrack(
            playlistId: fixture.playlistId,
            trackId: fixture.strangerId
        )

        #expect(member)
        #expect(!stranger)
    }

    @Test("an unknown playlist reads false rather than throwing")
    func unknownPlaylistReadsFalse() async throws {
        let fixture = try makeFixture()

        let answer = try await fixture.playlists.containsTrack(
            playlistId: fixture.playlistId + 9999,
            trackId: fixture.memberId
        )

        #expect(!answer)
    }

    /// A membership removed after the fact stops reading `true` — the read is a live
    /// query, not a snapshot taken when the repository was built.
    @Test("removing the membership flips the answer back to false")
    func removalFlipsTheAnswer() async throws {
        let fixture = try makeFixture()

        let removed = try await fixture.playlists.removeTrack(
            trackId: fixture.memberId,
            fromPlaylist: fixture.playlistId
        )
        let answer = try await fixture.playlists.containsTrack(
            playlistId: fixture.playlistId,
            trackId: fixture.memberId
        )

        #expect(removed == 1)
        #expect(!answer)
    }
}
