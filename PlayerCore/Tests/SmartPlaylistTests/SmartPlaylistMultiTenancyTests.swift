import Foundation
import GRDB
import Persistence
import PlayerCoreTestSupport
import Testing

/// The load-bearing profile-isolation proof: two profiles, disjoint library roots and
/// **byte-identical** rules must materialise disjoint playlists.
///
/// The rules are compared byte-for-byte first, so a passing result cannot be explained
/// by the two rule sets having quietly diverged — the only thing separating the
/// results is `LibraryVisibility`.
@Suite("SmartPlaylistMultiTenancyTests")
struct SmartPlaylistMultiTenancyTests {
    private static let firstPlaylistID: Int64 = 10
    private static let secondPlaylistID: Int64 = 11

    @Test("Identical rules under disjoint roots materialise disjoint playlists")
    func identicalRulesStayProfileScoped() throws {
        let database = try makeTwoProfileLibrary()
        let repository = SmartPlaylistRepository(
            database,
            now: FakeClock(SmartPlaylistFixtures.referenceNow).nowProvider
        )
        let rules = SmartPlaylistRules(predicates: [.metadata(.genre(equals: "Rock"))], limit: 50)
        try repository.setRules(rules, forPlaylist: Self.firstPlaylistID)
        try repository.setRules(rules, forPlaylist: Self.secondPlaylistID)

        let storedRules = try database.writer.read { db in
            try SmartPlaylistRecord.fetchAll(db).map(\.rulesJson)
        }
        let first = try repository.evaluate(playlistId: Self.firstPlaylistID)
        let second = try repository.evaluate(playlistId: Self.secondPlaylistID)

        #expect(storedRules.count == 2)
        #expect(storedRules[0] == storedRules[1])
        #expect(first.profileId == SmartPlaylistFixtures.profileID)
        #expect(second.profileId == SmartPlaylistFixtures.otherProfileID)
        #expect(first.trackIds.sorted() == [100, 101])
        #expect(second.trackIds.sorted() == [200, 201])
        #expect(Set(first.trackIds).isDisjoint(with: Set(second.trackIds)))
    }

    @Test("Materialised memberships are disjoint on disk, not just in the return value")
    func materialisedRowsAreDisjoint() throws {
        let database = try makeTwoProfileLibrary()
        let repository = SmartPlaylistRepository(
            database,
            now: FakeClock(SmartPlaylistFixtures.referenceNow).nowProvider
        )
        let rules = SmartPlaylistRules(predicates: [.metadata(.genre(equals: "Rock"))], limit: 50)
        try repository.setRules(rules, forPlaylist: Self.firstPlaylistID)
        try repository.setRules(rules, forPlaylist: Self.secondPlaylistID)
        try repository.evaluate(playlistId: Self.firstPlaylistID)
        try repository.evaluate(playlistId: Self.secondPlaylistID)

        let firstRows = try SmartPlaylistFixtures.membership(database, playlistId: Self.firstPlaylistID)
        let secondRows = try SmartPlaylistFixtures.membership(database, playlistId: Self.secondPlaylistID)

        #expect(firstRows.map(\.trackId) == [100, 101])
        #expect(secondRows.map(\.trackId) == [200, 201])
        #expect(Set(firstRows.map(\.trackId)).isDisjoint(with: Set(secondRows.map(\.trackId))))
    }

    /// Profile 2 owns `/A`, profile 3 owns `/B`, and each has two Rock tracks under
    /// its own root. Every track lives under *some* configured root, so nothing is
    /// ownerless and the two profiles share no visible rows at all.
    private func makeTwoProfileLibrary() throws -> AppDatabase {
        let database = try AppDatabase.makeEmpty()
        try database.writer.write { db in
            try SmartPlaylistFixtures.insertProfile(db, id: SmartPlaylistFixtures.profileID, name: "Profile A")
            try SmartPlaylistFixtures.insertProfile(db, id: SmartPlaylistFixtures.otherProfileID, name: "Profile B")
            try SmartPlaylistFixtures.insertRoot(db, profileId: SmartPlaylistFixtures.profileID, path: "/A")
            try SmartPlaylistFixtures.insertRoot(db, profileId: SmartPlaylistFixtures.otherProfileID, path: "/B")
            for (id, path) in [
                (Int64(100), "/A/one.flac"), (Int64(101), "/A/two.flac"),
                (Int64(200), "/B/one.flac"), (Int64(201), "/B/two.flac"),
            ] {
                var track = TrackRecord(id: id, filePath: path, availability: .present, genre: "Rock")
                try track.insert(db)
            }
            try SmartPlaylistFixtures.insertPlaylist(
                db,
                id: Self.firstPlaylistID,
                profileId: SmartPlaylistFixtures.profileID
            )
            try SmartPlaylistFixtures.insertPlaylist(
                db,
                id: Self.secondPlaylistID,
                profileId: SmartPlaylistFixtures.otherProfileID
            )
        }
        return database
    }
}
